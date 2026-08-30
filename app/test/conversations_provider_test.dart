import 'dart:async';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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
  void setConversationState(
    String source,
    String conversationKey,
    ConversationState state,
  ) {
    throw StateError('disk is full');
  }
}

void main() {
  late Database db;
  late MessageStore store;
  late FakeSync sync;

  void seedConversation(
    String key, {
    String state = 'needs_reply',
    String lastMessageAt = '2026-08-28T10:00:00Z',
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': key,
      'state': state,
      'last_message_at': lastMessageAt,
    });
  }

  void seedMessage(String key, String id) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'received_at': '2026-08-28T10:00:00Z',
      'body_text': 'body of $id',
    });
  }

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    sync = FakeSync();
  });

  tearDown(() => db.close());

  group('load', () {
    test('a first load ends Loaded with the stored rows', () async {
      seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      expect(notifier.state, isA<ConversationsInitial>());

      await notifier.load();

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.map((c) => c.id).toList(), ['c1']);
      expect(state.loadError, isNull);
      expect(sync.syncCalls, 1);
    });

    test('a failed refresh keeps the inbox and explains itself', () async {
      seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      sync.syncError = Exception('socket closed');
      seedConversation('c2', lastMessageAt: '2026-08-29T10:00:00Z');
      await notifier.load();

      final state = notifier.state as ConversationsLoaded;
      // Never blank: the rows stay, and the newly stored one still shows —
      // the sync failed, the local read did not.
      expect(state.conversations.map((c) => c.id).toList(), ['c2', 'c1']);
      expect(state.loadError, contains("Couldn't refresh"));
    });

    test('a refresh never falls back to a spinner', () async {
      seedConversation('c1');
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
      seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);

      await notifier.load(syncFirst: false);

      expect(sync.syncCalls, 0);
      expect((notifier.state as ConversationsLoaded).conversations.length, 1);
    });
  });

  group('out-of-order loads', () {
    test('a slow load that fails cannot stamp its error on a newer one',
        () async {
      seedConversation('c1');
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
      seedConversation('c1');
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
      seedConversation('c1');
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
      seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.markDone('c1');

      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.done,
      );
      expect(
        store.loadConversations(sources: const ['email']).single.state,
        ConversationState.done,
      );
    });

    test('a failed write puts the row back', () async {
      seedConversation('c1');
      final notifier = ConversationsNotifier(UnwritableStore(db), sync);
      await notifier.load();

      await notifier.markDone('c1');

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.needsReply);
      expect(state.loadError, contains("Couldn't save"));
    });

    test('does nothing before the first load', () async {
      final notifier = ConversationsNotifier(store, sync);
      await notifier.markDone('c1');
      expect(notifier.state, isA<ConversationsInitial>());
    });
  });

  group('thread', () {
    test('fetches bodies then reads the transcript', () async {
      seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'c1');

      await notifier.load();

      expect(sync.bodiesFetched, ['c1']);
      final state = notifier.state as ThreadLoaded;
      expect(state.messages.single.id, 'm1');
      expect(state.loadError, isNull);
    });

    test('a failed body fetch still shows what is stored', () async {
      seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'c1');
      sync.bodiesError = Exception('offline');

      await notifier.load();

      final state = notifier.state as ThreadLoaded;
      expect(state.messages.single.id, 'm1');
      expect(state.loadError, contains("Couldn't refresh"));
    });

    test('a later failure does not blank an already-loaded thread', () async {
      seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'c1');
      await notifier.load();

      sync.bodiesError = Exception('offline');
      await notifier.load();

      expect((notifier.state as ThreadLoaded).messages, hasLength(1));
    });

    test('fetchBodies false skips the network', () async {
      seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'c1');

      await notifier.load(fetchBodies: false);

      expect(sync.bodiesFetched, isEmpty);
      expect((notifier.state as ThreadLoaded).messages, hasLength(1));
    });

    test('a stale thread load writes nothing', () async {
      seedMessage('c1', 'm1');
      final notifier = ThreadNotifier(store, sync, 'c1');
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
      seedConversation('c1');
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        syncServiceProvider.overrideWithValue(sync),
      ]);
      addTearDown(container.dispose);

      await container.read(conversationsProvider.notifier).load();
      final state = container.read(conversationsProvider);
      expect((state as ConversationsLoaded).conversations.single.id, 'c1');

      await container.read(threadProvider('c1').notifier).load();
      expect(container.read(threadProvider('c1')), isA<ThreadLoaded>());
      expect(sync.bodiesFetched, ['c1']);
    });

    test('dbProvider refuses to guess at a database', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(() => container.read(dbProvider), throwsUnimplementedError);
    });
  });
}
