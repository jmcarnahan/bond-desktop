import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
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

/// A store whose label links fail while every state write lands — the
/// mark-done label step failing after the done flip has committed.
class LabelRefusingStore extends MessageStore {
  LabelRefusingStore(super.db);

  bool refuseApply = true;
  bool refuseRemove = false;

  @override
  Future<void> applyLabels(
    String source,
    String conversationKey,
    List<String> labelIds, {
    String appliedBy = 'user',
  }) async {
    if (refuseApply) throw StateError('database is locked');
    return super.applyLabels(source, conversationKey, labelIds,
        appliedBy: appliedBy);
  }

  @override
  Future<bool> removeLabel(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    if (refuseRemove) throw StateError('database is locked');
    return super.removeLabel(source, conversationKey, labelId);
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

  Future<void> seedMessage(
    String key,
    String id, {
    String direction = 'inbound',
    String receivedAt = '2026-08-28T10:00:00Z',
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': direction,
      'received_at': receivedAt,
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

    test('with no labels it hands back the state to come back to', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      final undo = await notifier.markDone('email', 'c1');

      expect(undo, isNotNull);
      expect(undo!.previousState, ConversationState.needsReply);
      expect(undo.appliedLabelIds, isEmpty);
      expect(undo.source, 'email');
      expect(undo.conversationKey, 'c1');
    });

    test('files the thread under the words it was given', () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final later = await store.createLabel('Later');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      final undo =
          await notifier.markDone('email', 'c1', labelIds: [fyi.id, later.id]);

      // Dismissing WITH a label is one action, so the chips are on the row in
      // the same step the state flipped — not after a second re-read.
      final row = (notifier.state as ConversationsLoaded).conversations.single;
      expect(row.state, ConversationState.done);
      expect([for (final l in row.labels) l.name], ['FYI only', 'Later']);
      expect(
        await store.labelsForConversation('email', 'c1'),
        hasLength(2),
      );
      expect(undo!.appliedLabelIds, [fyi.id, later.id]);
    });

    test('a word already on the thread is not this action\'s to undo',
        () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final later = await store.createLabel('Later');
      await store.applyLabels('email', 'c1', [fyi.id]);
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      final undo =
          await notifier.markDone('email', 'c1', labelIds: [fyi.id, later.id]);

      // The owner filed this thread under FYI only last week. Undoing today's
      // dismissal must not take that back.
      expect(undo!.appliedLabelIds, [later.id]);
    });

    test('a failed write applies no label and offers no undo', () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final notifier = ConversationsNotifier(UnwritableStore(db), sync);
      await notifier.load();

      final undo = await notifier.markDone('email', 'c1', labelIds: [fyi.id]);

      expect(undo, isNull);
      expect(await store.labelsForConversation('email', 'c1'), isEmpty);
      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.needsReply);
      expect(state.conversations.single.labels, isEmpty);
    });
  });

  group('markDone with a label that fails to save', () {
    test('keeps the done flip, says the label did not save, and undo reopens',
        () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final refusing = LabelRefusingStore(db);
      final notifier = ConversationsNotifier(refusing, sync);
      await notifier.load();

      final undo = await notifier.markDone('email', 'c1', labelIds: [fyi.id]);

      // The store says done, so the screen says done: a row snapped back to
      // needs-reply over a done thread would leave the pile at the next load
      // with no Undo.
      expect(
        (await store.loadConversations(sources: const ['email'])).single.state,
        ConversationState.done,
      );
      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.done);
      expect(state.conversations.single.labels, isEmpty);
      expect(await store.labelsForConversation('email', 'c1'), isEmpty);
      expect(state.loadError, "Marked done, but the label didn't save.");
      expect(undo, isNotNull);
      expect(undo!.appliedLabelIds, isEmpty);
      expect(undo.labelWriteFailed, isTrue);

      await notifier.undoMarkDone(undo);

      expect(
        (await store.loadConversations(sources: const ['email'])).single.state,
        ConversationState.needsReply,
      );
      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.needsReply,
      );
    });

    test('a clean label write reports no failure', () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      final undo = await notifier.markDone('email', 'c1', labelIds: [fyi.id]);

      expect(undo!.labelWriteFailed, isFalse);
    });
  });

  group('undoMarkDone with a label that fails to come off', () {
    test('keeps the restored state on screen and says the label stayed',
        () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final refusing = LabelRefusingStore(db)..refuseApply = false;
      final notifier = ConversationsNotifier(refusing, sync);
      await notifier.load();
      final undo = await notifier.markDone('email', 'c1', labelIds: [fyi.id]);
      refusing.refuseRemove = true;

      await notifier.undoMarkDone(undo!);

      // The store holds the restored state, so the screen does too.
      expect(
        (await store.loadConversations(sources: const ['email'])).single.state,
        ConversationState.needsReply,
      );
      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.needsReply);
      // And the chip the store still holds is still on the row.
      expect([for (final l in state.conversations.single.labels) l.id],
          [fyi.id]);
      expect(
        [for (final l in await store.labelsForConversation('email', 'c1')) l.id],
        [fyi.id],
      );
      expect(state.loadError, 'The thread is back, but the label is still on it.');
    });
  });

  group('undoMarkDone', () {
    test('puts the state back and takes off the labels it applied', () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();
      final undo = await notifier.markDone('email', 'c1', labelIds: [fyi.id]);

      await notifier.undoMarkDone(undo!);

      final row = (notifier.state as ConversationsLoaded).conversations.single;
      expect(row.state, ConversationState.needsReply);
      expect(row.labels, isEmpty);
      expect(
        (await store.loadConversations(sources: const ['email'])).single.state,
        ConversationState.needsReply,
      );
      expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    });

    test('leaves a label the dismissal did not apply', () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final later = await store.createLabel('Later');
      await store.applyLabels('email', 'c1', [fyi.id]);
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();
      final undo =
          await notifier.markDone('email', 'c1', labelIds: [fyi.id, later.id]);

      await notifier.undoMarkDone(undo!);

      final onThread = await store.labelsForConversation('email', 'c1');
      expect([for (final l in onThread) l.id], [fyi.id]);
      expect(
        [
          for (final l
              in (notifier.state as ConversationsLoaded).conversations.single
                  .labels)
            l.id,
        ],
        [fyi.id],
      );
    });

    test('a dismissal with no labels is still one press back', () async {
      await seedConversation('c1', state: 'waiting');
      await seedMessage('c1', 'm1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();
      final undo = await notifier.markDone('email', 'c1');

      await notifier.undoMarkDone(undo!);

      // Recorded rather than re-derived, which is the difference from
      // `reopenThread`: that one reads the newest message's direction and would
      // call this thread `needs_reply` on an inbound last message. A thread the
      // owner had parked comes back parked.
      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.waiting,
      );
    });

    test('a failed write leaves the thread dismissed and says so', () async {
      await seedConversation('c1');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();
      final undo = await notifier.markDone('email', 'c1');

      final refusing = ConversationsNotifier(UnwritableStore(db), sync);
      await refusing.load();
      await refusing.undoMarkDone(undo!);

      final state = refusing.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.done);
      expect(state.loadError, contains("Couldn't undo"));
    });

    test('the popularity of a word it removes stays where it was', () async {
      await seedConversation('c1');
      final fyi = await store.createLabel('FYI only');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();
      final undo = await notifier.markDone('email', 'c1', labelIds: [fyi.id]);

      await notifier.undoMarkDone(undo!);

      // `use_count` is how often the owner reached for the word, not a
      // refcount — see `MessageStore.removeLabel`.
      expect((await store.listLabels()).single.useCount, 1);
    });
  });

  group('reopenThread', () {
    test('their message last means the user owes a reply', () async {
      await seedConversation('c1', state: 'done');
      await seedMessage('c1', 'm1', direction: 'outbound');
      await seedMessage(
        'c1',
        'm2',
        receivedAt: '2026-08-28T11:00:00Z',
      );
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.reopenThread('email', 'c1');

      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.needsReply,
      );
      expect(
        (await store.loadConversations(sources: const ['email'])).single.state,
        ConversationState.needsReply,
      );
    });

    test('the user speaking last means they are waiting on somebody',
        () async {
      await seedConversation('c1', state: 'done');
      await seedMessage('c1', 'm1');
      await seedMessage(
        'c1',
        'm2',
        direction: 'outbound',
        receivedAt: '2026-08-28T11:00:00Z',
      );
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.reopenThread('email', 'c1');

      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.waiting,
      );
    });

    test('a thread with no messages asks nothing of anyone', () async {
      await seedConversation('c1', state: 'done');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.reopenThread('email', 'c1');

      expect(
        (notifier.state as ConversationsLoaded).conversations.single.state,
        ConversationState.waiting,
      );
    });

    test('a thread closed out of Later comes out of Later with it', () async {
      await seedConversation('c1', state: 'done');
      await seedMessage('c1', 'm1');
      await store.setConversationBucket(
        'email',
        'c1',
        bucket: 'later',
        reason: 'ai',
      );
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.reopenThread('email', 'c1');

      expect(
        (notifier.state as ConversationsLoaded).conversations.single.bucket,
        isNull,
      );
      final rows = await store.loadConversations(sources: const ['email']);
      expect(rows.single.bucket, isNull);
      // As the user, so the scoring sweep cannot defer it again on the next
      // pass — reopening IS the person saying this belongs in the inbox.
      expect((await store.bucketReasons())['c1'], 'user');
    });

    test('a thread that was never deferred keeps its empty bucket', () async {
      await seedConversation('c1', state: 'done');
      final notifier = ConversationsNotifier(store, sync);
      await notifier.load();

      await notifier.reopenThread('email', 'c1');

      expect((await store.bucketReasons())['c1'], isNull);
    });

    test('a failed write puts the row back', () async {
      await seedConversation('c1', state: 'done');
      await seedMessage('c1', 'm1');
      final notifier = ConversationsNotifier(UnwritableStore(db), sync);
      await notifier.load();

      await notifier.reopenThread('email', 'c1');

      final state = notifier.state as ConversationsLoaded;
      expect(state.conversations.single.state, ConversationState.done);
      expect(state.loadError, contains("Couldn't save"));
    });

    test('does nothing before the first load', () async {
      final notifier = ConversationsNotifier(store, sync);
      await notifier.reopenThread('email', 'c1');
      expect(notifier.state, isA<ConversationsInitial>());
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
      // The prefs load is fire-and-forget by design; waiting for it here is
      // what keeps its last read off a database this test has already closed.
      await container.read(appPrefsProvider.notifier).ready;

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
