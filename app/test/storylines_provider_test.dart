import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/providers/storylines_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// A handler that does nothing, so a [AiWorker.pump] emits one [WorkProgress]
/// of the kind asked for and finishes. The real worker is used rather than a
/// stand-in stream because what is being pinned is that the notifier filters
/// the kinds the real worker actually reports.
class SilentHandler extends WorkHandler {
  @override
  final String kind;

  SilentHandler(this.kind);

  @override
  Future<void> run(Map<String, Object?> item) async {}
}

/// A handler that parks on a gate the test opens, so a queue can be looked at
/// while an item of it is genuinely still in flight.
class BlockingHandler extends WorkHandler {
  @override
  final String kind;

  final Completer<void> gate = Completer<void>();

  BlockingHandler(this.kind);

  @override
  Future<void> run(Map<String, Object?> item) => gate.future;
}

/// Never called — every notifier method under test is a local write.
class UnusedLlm extends LlmClient {
  UnusedLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');
}

/// A store whose storyline reads fail, for the never-blank rule. Each read has
/// its own switch: the two notifiers under test fail independently.
class UnreadableStore extends MessageStore {
  UnreadableStore(super.db);

  bool broken = false;
  bool timelineBroken = false;

  @override
  Future<List<Storyline>> loadStorylines({
    List<String> statuses = const ['suggested', 'active'],
  }) async {
    if (broken) throw StateError('disk is gone');
    return super.loadStorylines(statuses: statuses);
  }

  @override
  Future<List<Map<String, Object?>>> storylineTimeline(
    String storylineId, {
    List<String> sources = const ['email'],
  }) async {
    if (timelineBroken) throw StateError('disk is gone');
    return super.storylineTimeline(storylineId, sources: sources);
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late StorylineService service;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    service = StorylineService(store, UnusedLlm());
  });

  tearDown(() => db.close());

  Future<void> seedStoryline(
    String id, {
    String status = 'suggested',
    String title = 'Website redesign',
  }) {
    return store.insertStoryline(
      id: id,
      title: title,
      status: status,
      createdBy: 'auto',
    );
  }

  Future<void> seedConversation(
    String key, {
    String? subject,
    String state = 'waiting',
    String? ctaText,
  }) {
    return store.upsertConversation({
      'conversation_key': key,
      'subject': subject ?? key,
      'state': state,
      'cta_text': ctaText,
      'last_message_at': '2026-08-28T10:00:00Z',
    });
  }

  Future<void> seedMessage(
    String key,
    String id, {
    required String receivedAt,
    String? subject,
    String source = 'email',
    String? fromName,
    String? fromAddress,
  }) {
    return store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'received_at': receivedAt,
      'subject': subject ?? key,
      'from_name': fromName,
      'from_address': fromAddress,
      'body_text': 'body of $id',
    });
  }

  group('load', () {
    test('a first load ends Loaded with the stored rows', () async {
      await seedStoryline('sl-1');
      final notifier = StorylinesNotifier(store, service);
      expect(notifier.state, isA<StorylinesInitial>());

      await notifier.load();

      final state = notifier.state as StorylinesLoaded;
      expect(state.storylines.map((s) => s.id), ['sl-1']);
      expect(state.loadError, isNull);
    });

    test('dismissed storylines never reach the list', () async {
      await seedStoryline('sl-1', status: 'dismissed');
      final notifier = StorylinesNotifier(store, service);

      await notifier.load();

      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);
    });

    test('dismissed storylines ride on their own list', () async {
      await seedStoryline('sl-1', status: 'dismissed', title: 'Old thing');
      await seedStoryline('sl-2', status: 'active');
      final notifier = StorylinesNotifier(store, service);

      await notifier.load();

      final state = notifier.state as StorylinesLoaded;
      expect(state.storylines.map((s) => s.id), ['sl-2']);
      expect(state.dismissed.map((s) => s.id), ['sl-1']);
    });

    test('a failed re-read keeps the rows and explains itself', () async {
      await seedStoryline('sl-1');
      final broken = UnreadableStore(db);
      final notifier = StorylinesNotifier(broken, service);
      await notifier.load();

      broken.broken = true;
      await notifier.load();

      final state = notifier.state as StorylinesLoaded;
      expect(state.storylines, hasLength(1));
      expect(state.loadError, contains("Couldn't refresh"));
    });

    test('a failure with nothing loaded yet is an error state', () async {
      final broken = UnreadableStore(db)..broken = true;
      final notifier = StorylinesNotifier(broken, service);

      await notifier.load();

      expect(notifier.state, isA<StorylinesError>());
    });
  });

  group('user actions', () {
    test('keep flips the status and reloads', () async {
      await seedStoryline('sl-1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.keep('sl-1');

      expect((notifier.state as StorylinesLoaded).storylines.single.status,
          'active');
      expect((await store.getStoryline('sl-1'))!.status, 'active');
    });

    test('dismiss takes it off the list entirely', () async {
      await seedStoryline('sl-1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.dismiss('sl-1');

      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);
      expect((await store.getStoryline('sl-1'))!.status, 'dismissed');
    });

    test('rename writes through and locks the title', () async {
      await seedStoryline('sl-1', status: 'active');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.rename('sl-1', 'Brightsea launch');

      final storyline =
          (notifier.state as StorylinesLoaded).storylines.single;
      expect(storyline.title, 'Brightsea launch');
      expect(storyline.titleLocked, isTrue);
    });

    test('add and remove move the member count', () async {
      await seedStoryline('sl-1', status: 'active');
      await seedConversation('c1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.addThread('sl-1', 'email', 'c1');
      expect((notifier.state as StorylinesLoaded).storylines.single.memberCount,
          1);

      await notifier.removeThread('sl-1', 'email', 'c1');
      expect((notifier.state as StorylinesLoaded).storylines.single.memberCount,
          0);
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isTrue);
    });

    test('accepting a suggestion routes through setCharter', () async {
      await seedStoryline('sl-1', status: 'active');
      await store.updateStoryline('sl-1',
          charter: 'The homepage threads.',
          charterLocked: true,
          charterSuggestion: 'The homepage threads and the press briefing.');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.acceptCharterSuggestion(
          'sl-1', 'The homepage threads and the press briefing.');

      // Accepting the model's sentence is the user saying it, so it lands as
      // a save would: locked, the suggestion answered, and the recruit that
      // any charter save queues waiting to run.
      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.charter, 'The homepage threads and the press briefing.');
      expect(storyline.charterLocked, isTrue);
      expect(storyline.charterSuggestion, isNull);
      expect((await store.nextPendingWork('storyline_recruit'))?['entity_id'],
          'sl-1');
    });

    test('dismissing clears only the suggestion', () async {
      await seedStoryline('sl-1', status: 'active');
      await store.updateStoryline('sl-1',
          charter: 'The homepage threads.',
          charterLocked: true,
          charterSuggestion: 'The homepage threads and the press briefing.');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.dismissCharterSuggestion('sl-1');

      final storyline =
          (notifier.state as StorylinesLoaded).storylines.single;
      expect(storyline.charterSuggestion, isNull);
      expect(storyline.charter, 'The homepage threads.');
      expect(storyline.charterLocked, isTrue);
      // Nothing was queued: the user's own charter has not moved.
      expect(await store.nextPendingWork('storyline_recruit'), isNull);
    });

    test('undismiss puts the question back on the live list', () async {
      await seedStoryline('sl-1', status: 'dismissed');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();
      expect((notifier.state as StorylinesLoaded).dismissed, hasLength(1));

      await notifier.undismiss('sl-1');

      final state = notifier.state as StorylinesLoaded;
      expect(state.dismissed, isEmpty);
      expect(state.storylines.single.status, 'suggested');
    });

    test('unblockThread lifts the block and reloads', () async {
      await seedStoryline('sl-1', status: 'active');
      await seedConversation('c1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();
      await notifier.addThread('sl-1', 'email', 'c1');
      await notifier.removeThread('sl-1', 'email', 'c1');
      expect(await store.blocksOf('sl-1'), hasLength(1));

      await notifier.unblockThread('sl-1', 'email', 'c1');

      expect(await store.blocksOf('sl-1'), isEmpty);
      // Withdrawing the veto is not filing the thread back.
      expect((notifier.state as StorylinesLoaded).storylines.single.memberCount,
          0);
    });

    test('auditNow leaves a re-check waiting for the worker', () async {
      await seedStoryline('sl-1', status: 'active');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.auditNow('sl-1');

      expect((await store.nextPendingWork('storyline_audit'))?['entity_id'],
          'sl-1');
      // And the read model says so, which is what makes the button inert:
      // pressing Add back under a pass that is mid-flight is how a thread
      // gets removed and re-filed in the same minute.
      expect((notifier.state as StorylinesLoaded).auditing, {'sl-1'});
    });

    test('a re-check nobody ever reports on is released by the backstop',
        () async {
      // No worker at all: the item is queued and nothing will drain it. A
      // model server that is down parks it the same way, and the button
      // must not stay inert until somebody restarts the server.
      await seedStoryline('sl-1', status: 'active');
      final notifier = StorylinesNotifier(
        store,
        service,
        auditBackstop: const Duration(milliseconds: 20),
      );
      addTearDown(notifier.dispose);
      await notifier.load();

      await notifier.auditNow('sl-1');
      expect((notifier.state as StorylinesLoaded).auditing, {'sl-1'});

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((notifier.state as StorylinesLoaded).auditing, isEmpty);
    });

    test('a second re-check does not hold the first one\'s release',
        () async {
      await seedStoryline('sl-1', status: 'active');
      await seedStoryline('sl-2', status: 'active');
      final notifier = StorylinesNotifier(
        store,
        service,
        auditBackstop: const Duration(milliseconds: 60),
      );
      addTearDown(notifier.dispose);
      await notifier.load();

      await notifier.auditNow('sl-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await notifier.auditNow('sl-2');
      await Future<void>.delayed(const Duration(milliseconds: 45));

      // The first has had its sixty milliseconds; the second has not.
      expect((notifier.state as StorylinesLoaded).auditing, {'sl-2'});
    });

    test('a storyline nobody re-checked is not marked as running', () async {
      await seedStoryline('sl-1', status: 'active');
      await seedStoryline('sl-2', status: 'active');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.auditNow('sl-1');

      expect((notifier.state as StorylinesLoaded).auditing, isNot(contains(
        'sl-2',
      )));
    });

    test('create returns the new id and lands it in the list', () async {
      await seedConversation('c1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      final id = await notifier.create('Brightsea launch', conversationKey: 'c1');

      final storylines = (notifier.state as StorylinesLoaded).storylines;
      expect(storylines.single.id, id);
      expect(storylines.single.status, 'active');
      expect(storylines.single.memberCount, 1);
    });
  });

  group('worker progress', () {
    /// Long enough for the 400ms debounce to fire.
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 600));

    test('a storyline-kind report reloads the list', () async {
      final worker = AiWorker(store, handlers: [SilentHandler('storyline')]);
      addTearDown(worker.dispose);
      final notifier = StorylinesNotifier(store, service, aiWorker: worker);
      addTearDown(notifier.dispose);
      await notifier.load();
      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);

      // What an assignment landing looks like from the outside: a row appears
      // in the database and the worker reports.
      await seedStoryline('sl-1');
      await worker.pump();
      await settle();

      expect((notifier.state as StorylinesLoaded).storylines, hasLength(1));
    });

    test('a sweep report reloads too', () async {
      final worker =
          AiWorker(store, handlers: [SilentHandler('storyline_sweep')]);
      addTearDown(worker.dispose);
      final notifier = StorylinesNotifier(store, service, aiWorker: worker);
      addTearDown(notifier.dispose);
      await notifier.load();

      await seedStoryline('sl-1');
      await worker.pump();
      await settle();

      expect((notifier.state as StorylinesLoaded).storylines, hasLength(1));
    });

    // All three rewrite the row the list renders — refresh the title, summary
    // and charter, recap the paragraph the header leads with, and an audit the
    // member count — so all three have to land on screen without waiting for
    // the next poll.
    for (final kind in const [
      'storyline_refresh',
      'storyline_recap',
      'storyline_audit',
    ]) {
      test('a $kind report reloads too', () async {
        final worker = AiWorker(store, handlers: [SilentHandler(kind)]);
        addTearDown(worker.dispose);
        final notifier = StorylinesNotifier(store, service, aiWorker: worker);
        addTearDown(notifier.dispose);
        await notifier.load();

        await seedStoryline('sl-1');
        await worker.pump();
        await settle();

        expect((notifier.state as StorylinesLoaded).storylines, hasLength(1));
      });
    }

    test('a finished audit releases the storyline it was asked about',
        () async {
      await seedStoryline('sl-1', status: 'active');
      final handler = BlockingHandler('storyline_audit');
      final worker = AiWorker(store, handlers: [handler]);
      addTearDown(worker.dispose);
      final notifier = StorylinesNotifier(store, service, aiWorker: worker);
      addTearDown(notifier.dispose);
      await notifier.load();

      await notifier.auditNow('sl-1');
      // The item is claimed and parked at the handler, so the pass really is
      // in flight while this is read.
      await settle();
      expect((notifier.state as StorylinesLoaded).auditing, {'sl-1'});

      handler.gate.complete();
      await settle();

      // Nothing remaining on the audit queue is what releases it — and the
      // reload that follows republishes with the emptied set.
      expect((notifier.state as StorylinesLoaded).auditing, isEmpty);
    });

    test('another queue\'s report changes nothing', () async {
      final worker = AiWorker(store, handlers: [SilentHandler('extract')]);
      addTearDown(worker.dispose);
      final notifier = StorylinesNotifier(store, service, aiWorker: worker);
      addTearDown(notifier.dispose);
      await notifier.load();

      // Extraction reports once per message. Reloading the storyline list on
      // every one of those would be a full read per email.
      await seedStoryline('sl-1');
      await worker.pump();
      await settle();

      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);
    });
  });

  group('timeline', () {
    /// The two-thread storyline every case below starts from: c1 opens, c2
    /// answers, c1 closes. Interleaved in time, so a view that merged them by
    /// timestamp would split each thread in half.
    Future<void> seedTwoThreads() async {
      await seedConversation('c1', subject: 'Re: Homepage copy');
      await seedConversation('c2', subject: 'Launch date');
      await seedMessage('c1', 'm1',
          receivedAt: '2026-08-01T09:00:00Z', subject: 'Re: Homepage copy');
      await seedMessage('c2', 'm2',
          receivedAt: '2026-08-01T10:00:00Z', subject: 'Launch date');
      await seedMessage('c1', 'm3',
          receivedAt: '2026-08-01T11:00:00Z', subject: 'Re: Re: Homepage copy');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');
    }

    test('groups the member threads into one episode each', () async {
      await seedTwoThreads();
      final notifier = StorylineTimelineNotifier(store, 'sl-1');

      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      // Ordered by last activity, oldest first: c1's second message is the
      // newest thing in the storyline, so its episode sorts last.
      expect(state.episodes.map((e) => e.conversationKey), ['c2', 'c1']);
      expect(state.episodes.first.messages.map((m) => m.id), ['m2']);
      expect(state.episodes.last.messages.map((m) => m.id), ['m1', 'm3']);
      expect(state.episodes.last.latestAt, '2026-08-01T11:00:00Z');
      expect(state.episodes.last.threadKey, 'email\nc1');
      expect(state.loadError, isNull);
    });

    test('the first non-empty subject names the thread', () async {
      await seedTwoThreads();
      final notifier = StorylineTimelineNotifier(store, 'sl-1');

      await notifier.load();

      // Stripped, so the label matches the one on the inbox row — and taken
      // from the first message, not the `Re: Re:` one that closed the thread.
      final state = notifier.state as StorylineTimelineLoaded;
      expect(
        {for (final e in state.episodes) e.conversationKey: e.subject},
        {'c1': 'Homepage copy', 'c2': 'Launch date'},
      );
    });

    test('a thread whose first message has no subject takes the next one',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z',
          subject: '');
      await seedMessage('c1', 'm2',
          receivedAt: '2026-08-01T10:00:00Z', subject: 'Homepage copy');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.subject, 'Homepage copy');
    });

    test('participants are the senders, deduped, in the order they spoke',
        () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1',
          receivedAt: '2026-08-01T09:00:00Z',
          fromName: 'Sarah Chen',
          fromAddress: 'sarah@example.com');
      await seedMessage('c1', 'm2',
          receivedAt: '2026-08-01T10:00:00Z',
          fromAddress: 'eric@example.com');
      await seedMessage('c1', 'm3',
          receivedAt: '2026-08-01T11:00:00Z',
          fromName: 'Sarah Chen',
          fromAddress: 'sarah@example.com');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      // A sender with no display name is their address rather than a gap —
      // the card names who is in the thread, and half a list is worse than a
      // raw address.
      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.participants,
          ['Sarah Chen', 'eric@example.com']);
    });

    test('an episode with no timestamp sorts first', () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await store.upsertMessage({
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'subject': 'Undated',
        'body_text': 'body of m1',
      });
      await seedMessage('c2', 'm2', receivedAt: '2026-08-01T10:00:00Z');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      // Nothing about an undated thread says it is the latest, and the last
      // card is the one that opens.
      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.map((e) => e.conversationKey), ['c1', 'c2']);
      expect(state.episodes.first.latestAt, isNull);
    });

    test('the episode carries the newest inbound triage summary', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedMessage('c1', 'm2', receivedAt: '2026-08-01T10:00:00Z');
      await store.writeTriage(
        'email',
        'm2',
        status: 'ok',
        result: const TriageResult(
          urgency: 'normal',
          category: 'other',
          summary: 'The studio wants the hero paragraph cut.',
          needsAction: false,
          actionItems: [],
        ),
      );
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.summary,
          'The studio wants the hero paragraph cut.');
    });

    test('a thread triage has not reached carries no summary', () async {
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.summary, isNull);
    });

    test('the episode carries the thread\'s state and its ask', () async {
      await seedConversation('c1',
          state: 'needs_reply',
          ctaText: 'Confirm availability for dinner on Friday');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      // Straight off the conversation row, so the card can say the thread
      // needs the user by the same rule the thread panel uses.
      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.state, ConversationState.needsReply);
      expect(state.episodes.single.ctaText,
          'Confirm availability for dinner on Friday');
    });

    test('a thread with no conversation row asks for nothing', () async {
      // Messages and membership without the conversation row the fold writes:
      // the episode still renders, and it demands nothing of the user.
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.state, ConversationState.waiting);
      expect(state.episodes.single.ctaText, isNull);
    });

    test('a needs-reply thread with no ask carries none', () async {
      await seedConversation('c1', state: 'needs_reply');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes.single.state, ConversationState.needsReply);
      expect(state.episodes.single.ctaText, isNull);
    });

    test('a failed re-read keeps the episodes and explains itself', () async {
      await seedTwoThreads();
      final broken = UnreadableStore(db);
      final notifier = StorylineTimelineNotifier(broken, 'sl-1');
      await notifier.load();

      broken.timelineBroken = true;
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes, hasLength(2));
      expect(state.loadError, contains("Couldn't refresh"));
    });

    test('an empty storyline loads as empty rather than erroring', () async {
      await seedStoryline('sl-1', status: 'active');
      final notifier = StorylineTimelineNotifier(store, 'sl-1');

      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.episodes, isEmpty);
    });

    test('a storyline-kind report reloads the spine too', () async {
      // The member strip's providers refresh on worker progress; a spine that
      // waited for the 60s poll would disagree with the strip for up to a
      // minute — "3 threads" in the header over two cards.
      final worker = AiWorker(store, handlers: [SilentHandler('storyline')]);
      addTearDown(worker.dispose);
      await seedTwoThreads();
      final notifier =
          StorylineTimelineNotifier(store, 'sl-1', aiWorker: worker);
      addTearDown(notifier.dispose);
      await notifier.load();
      expect(
          (notifier.state as StorylineTimelineLoaded).episodes, hasLength(2));

      // What an assignment landing looks like from the outside: a member row
      // appears and the worker reports.
      await seedConversation('c3', subject: 'Photography');
      await seedMessage('c3', 'm4',
          receivedAt: '2026-08-01T12:00:00Z', subject: 'Photography');
      await store.addStorylineMember('sl-1', 'email', 'c3', addedBy: 'auto');
      await worker.pump();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(
          (notifier.state as StorylineTimelineLoaded).episodes, hasLength(3));
    });
  });

  group('the documents provider', () {
    Future<List<String>> documentsOf(String storylineId) async {
      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
      ]);
      addTearDown(container.dispose);
      final documents =
          await container.read(storylineDocumentsProvider(storylineId).future);
      return [for (final document in documents) document.name ?? ''];
    }

    test('the shelf is every document on the storyline, pinned first',
        () async {
      await seedStoryline('sl-1', status: 'active');
      await seedConversation('c1');
      await seedConversation('c2');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedMessage('c2', 'm2', receivedAt: '2026-08-20T09:00:00Z');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');
      await store.upsertAttachments('email', 'm1', [
        {
          'attachment_id': 'a1',
          'ordinal': 0,
          'kind': 'file',
          'name': 'Old.pdf',
          'content_type': 'application/pdf',
          'size': 1024,
        },
      ]);
      await store.upsertAttachments('email', 'm2', [
        {
          'attachment_id': 'a2',
          'ordinal': 0,
          'kind': 'file',
          'name': 'New.pdf',
          'content_type': 'application/pdf',
          'size': 1024,
        },
      ]);

      // Newest message first while nothing is pinned.
      expect(await documentsOf('sl-1'), ['New.pdf', 'Old.pdf']);

      // A pin floats the older one over it, which is the whole point of one.
      await store.setAttachmentPinned('email', 'm1', 'a1', 'sl-1');
      expect(await documentsOf('sl-1'), ['Old.pdf', 'New.pdf']);
    });

    test('a storyline whose threads carry no files reads empty', () async {
      await seedStoryline('sl-1', status: 'active');
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      expect(await documentsOf('sl-1'), isEmpty);
    });
  });

  group('provider wiring', () {
    test('the providers build against an overridden db', () async {
      await seedStoryline('sl-1', status: 'active');
      await seedConversation('c1');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
      ]);
      addTearDown(container.dispose);

      // The AI worker behind this provider reaches the attachment backend, and
      // that one is chosen by a stored preference — so building it starts a
      // fire-and-forget read of `app_prefs`. Awaiting it here is what keeps
      // that read inside the life of the database this test closes.
      await container.read(appPrefsProvider.notifier).ready;

      await container.read(storylinesProvider.notifier).load();
      final state = container.read(storylinesProvider) as StorylinesLoaded;
      expect(state.storylines.single.id, 'sl-1');

      await container.read(storylineTimelineProvider('sl-1').notifier).load();
      final timeline = container.read(storylineTimelineProvider('sl-1'));
      expect(
        (timeline as StorylineTimelineLoaded).episodes.single.messages.single.id,
        'm1',
      );
    });
  });
}
