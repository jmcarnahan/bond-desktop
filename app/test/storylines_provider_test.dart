import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/storylines_provider.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/llm/llm_client.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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

/// Never called — every notifier method under test is a local write.
class UnusedLlm extends LlmClient {
  UnusedLlm() : super(baseUrl: 'http://127.0.0.1:1/never-dialled');
}

/// A store whose storyline read fails, for the never-blank rule.
class UnreadableStore extends MessageStore {
  UnreadableStore(super.db);

  bool broken = false;

  @override
  List<Storyline> loadStorylines({
    List<String> statuses = const ['suggested', 'active'],
  }) {
    if (broken) throw StateError('disk is gone');
    return super.loadStorylines(statuses: statuses);
  }
}

void main() {
  late Database db;
  late MessageStore store;
  late StorylineService service;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
    service = StorylineService(store, UnusedLlm());
  });

  tearDown(() => db.close());

  void seedStoryline(
    String id, {
    String status = 'suggested',
    String title = 'Willow St purchase',
  }) {
    store.insertStoryline(
      id: id,
      title: title,
      status: status,
      createdBy: 'auto',
    );
  }

  void seedConversation(String key, {String? subject}) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': subject ?? key,
      'state': 'waiting',
      'last_message_at': '2026-08-28T10:00:00Z',
    });
  }

  void seedMessage(
    String key,
    String id, {
    required String receivedAt,
    String? subject,
  }) {
    store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'received_at': receivedAt,
      'subject': subject ?? key,
      'body_text': 'body of $id',
    });
  }

  group('load', () {
    test('a first load ends Loaded with the stored rows', () async {
      seedStoryline('sl-1');
      final notifier = StorylinesNotifier(store, service);
      expect(notifier.state, isA<StorylinesInitial>());

      await notifier.load();

      final state = notifier.state as StorylinesLoaded;
      expect(state.storylines.map((s) => s.id), ['sl-1']);
      expect(state.loadError, isNull);
    });

    test('dismissed storylines never reach the list', () async {
      seedStoryline('sl-1', status: 'dismissed');
      final notifier = StorylinesNotifier(store, service);

      await notifier.load();

      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);
    });

    test('a failed re-read keeps the rows and explains itself', () async {
      seedStoryline('sl-1');
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
      seedStoryline('sl-1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.keep('sl-1');

      expect((notifier.state as StorylinesLoaded).storylines.single.status,
          'active');
      expect(store.getStoryline('sl-1')!.status, 'active');
    });

    test('dismiss takes it off the list entirely', () async {
      seedStoryline('sl-1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.dismiss('sl-1');

      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);
      expect(store.getStoryline('sl-1')!.status, 'dismissed');
    });

    test('rename writes through and locks the title', () async {
      seedStoryline('sl-1', status: 'active');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.rename('sl-1', 'Chen refinance');

      final storyline =
          (notifier.state as StorylinesLoaded).storylines.single;
      expect(storyline.title, 'Chen refinance');
      expect(storyline.titleLocked, isTrue);
    });

    test('add and remove move the member count', () async {
      seedStoryline('sl-1', status: 'active');
      seedConversation('c1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      await notifier.addThread('sl-1', 'email', 'c1');
      expect((notifier.state as StorylinesLoaded).storylines.single.memberCount,
          1);

      await notifier.removeThread('sl-1', 'email', 'c1');
      expect((notifier.state as StorylinesLoaded).storylines.single.memberCount,
          0);
      expect(store.isMemberBlocked('sl-1', 'email', 'c1'), isTrue);
    });

    test('create returns the new id and lands it in the list', () async {
      seedConversation('c1');
      final notifier = StorylinesNotifier(store, service);
      await notifier.load();

      final id = await notifier.create('Chen refinance', conversationKey: 'c1');

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
      seedStoryline('sl-1');
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

      seedStoryline('sl-1');
      await worker.pump();
      await settle();

      expect((notifier.state as StorylinesLoaded).storylines, hasLength(1));
    });

    test('another queue\'s report changes nothing', () async {
      final worker = AiWorker(store, handlers: [SilentHandler('extract')]);
      addTearDown(worker.dispose);
      final notifier = StorylinesNotifier(store, service, aiWorker: worker);
      addTearDown(notifier.dispose);
      await notifier.load();

      // Extraction reports once per message. Reloading the storyline list on
      // every one of those would be a full read per email.
      seedStoryline('sl-1');
      await worker.pump();
      await settle();

      expect((notifier.state as StorylinesLoaded).storylines, isEmpty);
    });
  });

  group('timeline', () {
    test('merges the member threads and names each one', () async {
      seedConversation('c1', subject: 'Re: Appraisal review');
      seedConversation('c2', subject: 'Rate lock');
      seedMessage('c1', 'm1',
          receivedAt: '2026-08-01T09:00:00Z', subject: 'Re: Appraisal review');
      seedMessage('c2', 'm2',
          receivedAt: '2026-08-01T10:00:00Z', subject: 'Rate lock');
      seedMessage('c1', 'm3',
          receivedAt: '2026-08-01T11:00:00Z', subject: 'Re: Appraisal review');
      seedStoryline('sl-1', status: 'active');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

      final notifier = StorylineTimelineNotifier(store, 'sl-1');
      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.messages.map((m) => m.id), ['m1', 'm2', 'm3']);
      expect(state.keyByMessageId, {'m1': 'c1', 'm2': 'c2', 'm3': 'c1'});
      // Stripped, so the label matches the one on the inbox row.
      expect(state.subjectByKey, {'c1': 'Appraisal review', 'c2': 'Rate lock'});
      expect(state.loadError, isNull);
    });

    test('an empty storyline loads as empty rather than erroring', () async {
      seedStoryline('sl-1', status: 'active');
      final notifier = StorylineTimelineNotifier(store, 'sl-1');

      await notifier.load();

      final state = notifier.state as StorylineTimelineLoaded;
      expect(state.messages, isEmpty);
      expect(state.subjectByKey, isEmpty);
    });
  });

  group('provider wiring', () {
    test('the providers build against an overridden db', () async {
      seedStoryline('sl-1', status: 'active');
      seedConversation('c1');
      seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final container = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
      ]);
      addTearDown(container.dispose);

      await container.read(storylinesProvider.notifier).load();
      final state = container.read(storylinesProvider) as StorylinesLoaded;
      expect(state.storylines.single.id, 'sl-1');

      await container.read(storylineTimelineProvider('sl-1').notifier).load();
      final timeline = container.read(storylineTimelineProvider('sl-1'));
      expect((timeline as StorylineTimelineLoaded).messages.single.id, 'm1');
    });
  });
}
