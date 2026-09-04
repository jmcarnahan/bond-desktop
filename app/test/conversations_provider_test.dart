import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/pipeline_progress.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// A [MailSync] that never touches a socket. [manual] holds each call open on
/// a completer so a test can finish two loads out of order on purpose.
class FakeSync implements MailSync {
  final List<Completer<void>> gates = [];
  final List<Completer<void>> bodyGates = [];
  final List<String> bodiesFetched = [];
  final List<String> messageBodiesFetched = [];
  bool manual = false;
  bool manualBodies = false;
  Object? syncError;
  Object? bodiesError;
  int syncCalls = 0;

  @override
  Future<void> syncNow() async {
    syncCalls++;
    if (manual) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    final error = syncError;
    if (error != null) throw error;
  }

  @override
  Future<void> ensureBodies(String conversationKey) async {
    bodiesFetched.add(conversationKey);
    if (manualBodies) {
      final gate = Completer<void>();
      bodyGates.add(gate);
      await gate.future;
    }
    final error = bodiesError;
    if (error != null) throw error;
  }

  /// The triage worker's per-message fetch. Recorded rather than exercised —
  /// these tests are about the read model, and none of them run a queue.
  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {
    messageBodiesFetched.add(sourceMessageId);
  }
}

/// A store whose writes fail, for the optimistic-update revert.
class UnwritableStore extends MessageStore {
  UnwritableStore(super.db);

  @override
  Future<void> setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) async {
    throw StateError('disk is full');
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late FakeSync sync;

  Future<void> seedConversation(
    String key, {
    String state = 'needs_reply',
    String lastMessageAt = '2026-08-28T10:00:00Z',
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': lastMessageAt,
    });
  }

  Future<void> seedMessage(String key, String id) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'received_at': '2026-08-28T10:00:00Z',
      'body_text': 'body of $id',
    });
  }

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    sync = FakeSync();
  });

  tearDown(() => db.close());

  group('load', () {
    test('a first load ends Loaded with the stored rows', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      expect(notifier.state, isA<ConversationsInitial>());

      await notifier.load();

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.map((c) => c.id).toList(), ['c1']);
      expect(state.loadError, isNull);
      expect(sync.syncCalls, 1);
    });

    test('a failed refresh keeps the inbox and explains itself', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      sync.syncError = Exception('socket closed');
      await seedConversation('c2', lastMessageAt: '2026-08-29T10:00:00Z');
      await notifier.load();

      final state = notifier.state as ConversationsLoaded;
      // Never blank: the rows stay, and the newly stored one still shows —
      // the sync failed, the local read did not.
      expect(state.conversations.map((c) => c.id).toList(), ['c2', 'c1']);
      expect(state.loadError, contains("Couldn't refresh"));
    });

    test('a refresh never falls back to a spinner', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      sync.manual = true;
      final pending = notifier.load();
      expect(notifier.state, isA<ConversationsLoaded>(),
          reason: 'a periodic refresh over a live inbox must not flash a '
              'loading state');
      sync.gates.single.complete();
      await pending;
      expect(notifier.state, isA<ConversationsLoaded>());
    });

    test('syncFirst false reads the store without a network call', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);

      await notifier.load(syncFirst: false);

      expect(sync.syncCalls, 0);
      expect((notifier.state as ConversationsLoaded).conversations.length, 1);
    });
  });

  group('out-of-order loads', () {
    test('a slow load that fails cannot stamp its error on a newer one',
        () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      sync.manual = true;

      final slow = notifier.load();
      final fresh = notifier.load();

      // The newer load lands first and cleanly.
      sync.gates[1].complete();
      await fresh;
      final settled = notifier.state as ConversationsLoaded;
      expect(settled.loadError, isNull);

      // The older one then fails. Without the sequence guard on the failure
      // path it would hang a stale banner on an inbox that just refreshed
      // successfully.
      sync.gates[0].completeError(Exception('slow failure'));
      await slow;

      expect(identical(notifier.state, settled), isTrue,
          reason: 'a stale load must write nothing at all');
    });

    test('a slow load that succeeds is discarded too', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      sync.manual = true;

      final slow = notifier.load();
      final fresh = notifier.load();

      sync.gates[1].complete();
      await fresh;
      final settled = notifier.state;

      sync.gates[0].complete();
      await slow;

      expect(identical(notifier.state, settled), isTrue);
    });
  });

  group('auth failures', () {
    test('a dead session with nothing stored routes to sign-in', () async {
      final notifier = ConversationsNotifier(store, sync);
      sync.syncError = const NotSignedIn('Session expired — sign in again.');

      await notifier.load();

      final state = notifier.state as ConversationsError;
      expect(state.signedOut, isTrue);
      expect(state.message, contains('Session expired'));
    });

    test('missing consent with nothing stored routes to sign-in', () async {
      final notifier = ConversationsNotifier(store, sync);
      sync.syncError = const ReconsentRequired();

      await notifier.load();

      expect((notifier.state as ConversationsError).signedOut, isTrue);
    });

    test('a dead session with an inbox already stored keeps the inbox',
        () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      sync.syncError = const NotSignedIn('Session expired — sign in again.');
      await notifier.load();

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.length, 1);
      expect(state.loadError, contains('Session expired'));
    });

    test('a generic AuthException never signs the user out', () async {
      final notifier = ConversationsNotifier(store, sync);
      // What a 5xx at Microsoft or an offline laptop produces. Signing out
      // over one costs the user their session for a dropped packet.
      sync.syncError = const AuthException('Could not reach Microsoft.');

      await notifier.load();

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations, isEmpty);
      expect(state.loadError, contains("Couldn't refresh"));
    });
  });

  group('markDone', () {
    test('flips the row and writes it through', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.markDone('email', 'c1');

      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.done,
      );
      expect(
        (await store.loadConversations(sources: const ['email'])).single.state,
        ConversationState.done,
      );
    });

    test('a failed write puts the row back', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(UnwritableStore(db), sync);
      await notifier.load();

      await notifier.markDone('email', 'c1');

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.needsReply);
      expect(state.loadError, contains("Couldn't save"));
    });

    test('does nothing before the first load', () async {
      final notifier = ConversationsNotifier(store, sync);
      await notifier.markDone('email', 'c1');
      expect(notifier.state, isA<ConversationsInitial>());
    });

    test('and it takes the Needs You chip off the thread', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1');
      await db.customUpdate(
        'UPDATE message_progress SET needs_you = 1 '
        'WHERE source_message_id = ?',
        variables: [Variable('m1')],
      );
      final notifier = ConversationsNotifier(
        store,
        sync,
        progress: PipelineProgress(store),
      );
      await notifier.load();

      await notifier.markDone('email', 'c1');

      // Finishing a thread is the user saying the ask is answered — the other
      // half of the exit a synced reply takes.
      final row = await db
          .customSelect(
            'SELECT needs_you FROM message_progress '
            'WHERE source_message_id = ?',
            variables: [Variable('m1')],
          )
          .getSingle();
      expect(row.data['needs_you'], 0);
    });

    test('a failed write leaves the chip exactly where it was', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1');
      await db.customUpdate(
        'UPDATE message_progress SET needs_you = 1 '
        'WHERE source_message_id = ?',
        variables: [Variable('m1')],
      );
      final notifier = ConversationsNotifier(
        UnwritableStore(db),
        sync,
        progress: PipelineProgress(store),
      );
      await notifier.load();

      await notifier.markDone('email', 'c1');

      final row = await db
          .customSelect(
            'SELECT needs_you FROM message_progress '
            'WHERE source_message_id = ?',
            variables: [Variable('m1')],
          )
          .getSingle();
      expect(row.data['needs_you'], 1);
    });
  });

  group('thread', () {
    test('fetches bodies then reads the transcript', () async {
      await seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'email', 'c1');

      await notifier.load();

      expect(sync.bodiesFetched, ['c1']);
      final state = notifier.state as ThreadLoaded;
      expect(state.messages.single.id, 'm1');
      expect(state.loadError, isNull);
    });

    test('a failed body fetch still shows what is stored', () async {
      await seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'email', 'c1');
      sync.bodiesError = Exception('offline');

      await notifier.load();

      final state = notifier.state as ThreadLoaded;
      expect(state.messages.single.id, 'm1');
      expect(state.loadError, contains("Couldn't refresh"));
    });

    test('a later failure does not blank an already-loaded thread', () async {
      await seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'email', 'c1');
      await notifier.load();

      sync.bodiesError = Exception('offline');
      await notifier.load();

      expect((notifier.state as ThreadLoaded).messages, hasLength(1));
    });

    test('fetchBodies false skips the network', () async {
      await seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'email', 'c1');

      await notifier.load(fetchBodies: false);

      expect(sync.bodiesFetched, isEmpty);
      expect((notifier.state as ThreadLoaded).messages, hasLength(1));
    });

    test('a chat thread asks for no bodies at all', () async {
      // [MailSync.ensureBodies] resolves what to fetch by loading the thread
      // for source `email`. A chat body arrives whole with the message, so the
      // call has nothing to do — and under a key shared with a mail thread it
      // would fetch THAT thread's bodies and hand this transcript its errors.
      await store.upsertMessage({
        'source': 'teams',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'received_at': '2026-08-28T10:00:00Z',
        'body_text': 'body of m1',
      });
      final notifier = ThreadNotifier(store, sync, 'teams', 'c1');

      await notifier.load();

      expect(sync.bodiesFetched, isEmpty);
      final state = notifier.state as ThreadLoaded;
      expect(state.messages.single.id, 'm1');
      expect(state.loadError, isNull);
    });

    test('a stale thread load writes nothing', () async {
      await seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'email', 'c1');
      sync.manualBodies = true;

      final slow = notifier.load();
      final fresh = notifier.load();

      sync.bodyGates[1].complete();
      await fresh;
      final settled = notifier.state;
      expect(settled, isA<ThreadLoaded>());

      // Selecting away and back re-runs load; the abandoned fetch must not
      // land on the thread the user is actually looking at.
      sync.bodyGates[0].completeError(Exception('slow failure'));
      await slow;

      expect(identical(notifier.state, settled), isTrue);
    });
  });

  group('provider wiring', () {
    test('the providers build against an overridden db and sync', () async {
      await seedConversation('c1');
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        syncServiceProvider.overrideWithValue(sync),
      ]);
      addTearDown(container.dispose);

      await container.read(conversationsProvider.notifier).load();
      final state = container.read(conversationsProvider);
      expect((state as ConversationsLoaded).conversations.single.id, 'c1');

      const target = (source: 'email', conversationKey: 'c1');
      await container.read(threadProvider(target).notifier).load();
      expect(container.read(threadProvider(target)), isA<ThreadLoaded>());
      expect(sync.bodiesFetched, ['c1']);
    });

    test('dbProvider refuses to guess at a database', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(() => container.read(dbProvider), throwsUnimplementedError);
    });
  });
}
