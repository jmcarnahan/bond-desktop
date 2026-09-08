import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_history.dart';
import 'package:bond_inbox/providers/message_history_provider.dart';
import 'package:bond_inbox/services/progress_bus.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// One message's story, assembled and kept current.
///
/// The notifier is built directly rather than through a container: it takes a
/// store, a bus and a threshold reader and nothing else, which is the point —
/// the screen over it has no way to reach the database except through this.
///
/// What the tests pin is that the story is TRUE of the row underneath: a
/// gate-dropped message shows the cascade its gate wrote, a filed thread shows
/// the filing with the evidence behind it, and a message nothing is stored
/// under says so instead of rendering half of one.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seed(
    String id, {
    String source = 'email',
    String conversationKey = 'c1',
    String triageStatus = 'triaged',
    String receivedAt = '2026-09-01T08:00:00Z',
  }) =>
      store.upsertMessage({
        'source': source,
        'source_message_id': id,
        'conversation_key': conversationKey,
        'direction': 'inbound',
        'subject': 'Renewal paperwork',
        'from_name': 'Dana Whitfield',
        'from_address': 'dana@example.com',
        'body_text': 'Could you look at the DPA before Friday?',
        'received_at': receivedAt,
        'triage_status': triageStatus,
      });

  MessageHistoryNotifier build(
    String id, {
    String source = 'email',
    ProgressBus bus = const ProgressBus.disabled(),
    double threshold = 0.5,
  }) {
    final notifier = MessageHistoryNotifier(
      store,
      source: source,
      sourceMessageId: id,
      bus: bus,
      threshold: () async => threshold,
    );
    addTearDown(notifier.dispose);
    return notifier;
  }

  MessageHistory storyOf(MessageHistoryNotifier notifier) =>
      notifier.state.value!;

  String stageState(MessageHistory story, String name) =>
      story.stages.firstWhere((stage) => stage.name == name).state;

  test('a gate-dropped message shows the cascade the gate wrote', () async {
    await seed('m1', triageStatus: 'skipped');
    await db.customUpdate(
      "UPDATE messages SET gate_reason = 'newsletter' "
      'WHERE source = ? AND source_message_id = ?',
      variables: [Variable('email'), Variable('m1')],
    );
    await store.writeTriageProgress(
      'email',
      'm1',
      state: 'skipped',
      gateReason: 'newsletter',
    );

    final notifier = build('m1');
    await notifier.load();
    final story = storyOf(notifier);

    expect(story.exists, isTrue);
    expect(story.gateReason, 'newsletter');
    expect(story.row!.dropped, isTrue);
    expect(story.row!.dropReason, 'newsletter');
    // The gate finishes the WHOLE row, not one stage of it: nothing downstream
    // is ever going to run, so the rail has to say so rather than sit at
    // `pending` forever.
    expect(stageState(story, 'triage'), 'skipped');
    expect(stageState(story, 'extract'), 'skipped');
    expect(stageState(story, 'storyline'), 'skipped');
    expect(stageState(story, 'draft'), 'skipped');
    expect(stageState(story, 'settle'), 'done');
  });

  test('a filed thread carries the filing and what it was filed on', () async {
    await seed('m1');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Acme renewal',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember(
      'sl-1',
      'email',
      'c1',
      addedBy: 'user',
      evidence: 'Same renewal thread',
    );

    final notifier = build('m1');
    await notifier.load();
    final story = storyOf(notifier);

    expect(story.memberships, hasLength(1));
    expect(story.memberships.single.storylineId, 'sl-1');
    expect(story.memberships.single.title, 'Acme renewal');
    expect(story.memberships.single.status, 'active');
    expect(story.memberships.single.evidence, 'Same renewal thread');
    expect(story.memberships.single.addedByUser, isTrue);
    expect(story.blocks, isEmpty);
  });

  test('a stalled row is stalled, and its queue is empty — which is the whole '
      'diagnosis', () async {
    final now = DateTime.utc(2026, 9, 1, 12);
    await seed('m1');
    await db.customUpdate(
      'UPDATE message_progress SET updated_at = ? '
      'WHERE source = ? AND source_message_id = ?',
      variables: [
        Variable(now.subtract(const Duration(minutes: 16)).toIso8601String()),
        Variable('email'),
        Variable('m1'),
      ],
    );

    final notifier = build('m1');
    await notifier.load();
    final story = storyOf(notifier);

    // Pending, nothing queued, and no progress write for longer than any
    // single stage takes. The empty work list is what turns "slow" into
    // "stuck": a row with something in flight is never stalled.
    expect(story.row!.isStalled(now), isTrue);
    expect(story.work, isEmpty);
  });

  test('a queued stage rides along under the message that owes it', () async {
    await seed('m1');
    await store.enqueueWork('extract', 'email', 'm1');
    await store.enqueueWork('storyline', 'email', 'c1');

    final notifier = build('m1');
    await notifier.load();

    expect(
      {for (final item in storyOf(notifier).work) item.kind},
      {'extract', 'storyline'},
    );
  });

  test('the threshold the score is read against comes back with it', () async {
    await seed('m1');
    await store.writeAttentionScore('email', 'c1', 0.71);
    await store.setConversationBucket(
      'email',
      'c1',
      bucket: 'needs_you',
      reason: 'asks a question',
    );

    final notifier = build('m1', threshold: 0.62);
    await notifier.load();
    final story = storyOf(notifier);

    expect(story.attentionScore, closeTo(0.71, 0.0001));
    expect(story.bucket, 'needs_you');
    expect(story.bucketReason, 'asks a question');
    // A score means nothing without the bar it was measured against, and the
    // owner can move the bar.
    expect(story.threshold, 0.62);
  });

  test('a message nothing is stored under says so instead of half a story',
      () async {
    final notifier = build('ghost');
    await notifier.load();
    final story = storyOf(notifier);

    expect(story.exists, isFalse);
    expect(story.sourceMessageId, 'ghost');
    expect(story.row, isNull);
    expect(story.stages, hasLength(5));
    expect(story.work, isEmpty);
    expect(story.events, isEmpty);
  });

  group('staying current', () {
    late ProgressBus bus;

    setUp(() => bus = ProgressBus());
    tearDown(() => bus.dispose());

    test('a tick about this message re-reads it', () async {
      await seed('m1');
      final notifier = build('m1', bus: bus);
      await notifier.load();
      expect(stageState(storyOf(notifier), 'extract'), 'pending');

      await store.writeExtractProgress('email', 'm1', state: 'done');
      bus.publish(const ProgressTick(
        source: 'email',
        sourceMessageId: 'm1',
        stage: 'extract',
        state: 'done',
        receivedAt: '2026-09-01T08:00:00Z',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(stageState(storyOf(notifier), 'extract'), 'done');
    });

    test('a tick about somebody else does not', () async {
      await seed('m1');
      await seed('m2', conversationKey: 'c2');
      final notifier = build('m1', bus: bus);
      await notifier.load();

      await store.writeExtractProgress('email', 'm1', state: 'done');
      bus.publish(const ProgressTick(
        source: 'email',
        sourceMessageId: 'm2',
        stage: 'extract',
        state: 'done',
        receivedAt: '2026-09-01T08:00:00Z',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // The write landed in the database and the screen has not been told, on
      // purpose: a per-message filter is what keeps a mailbox-wide sync from
      // re-reading this row a thousand times.
      expect(stageState(storyOf(notifier), 'extract'), 'pending');
    });

    test('reload is the door for the changes that tick nothing', () async {
      await seed('m1');
      final notifier = build('m1', bus: bus);
      await notifier.load();
      expect(storyOf(notifier).memberships, isEmpty);

      // Filing a thread by hand moves no stage, so nothing is published for
      // the subscription to hear — the screen asks again itself.
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Acme renewal',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'user');
      await notifier.reload();

      expect(storyOf(notifier).memberships, hasLength(1));
    });
  });

  group('assemble', () {
    test('a message with no progress row reads as five stages that never ran',
        () {
      final story = MessageHistory.assemble(
        source: 'email',
        sourceMessageId: 'm1',
        message: const {
          'conversation_key': 'c1',
          'subject': 'Renewal paperwork',
          'triage_status': 'pending',
          'needs_you_verdict': null,
        },
        conversation: null,
        conversationAi: null,
        progress: null,
        row: null,
        work: const [],
        memberships: const [],
        blocks: const [],
        activity: const [],
        threshold: 0.5,
      );

      expect(story.exists, isTrue);
      expect(story.conversationKey, 'c1');
      expect(story.row, isNull);
      expect([for (final stage in story.stages) stage.name],
          ['triage', 'extract', 'storyline', 'draft', 'settle']);
      expect([for (final stage in story.stages) stage.state],
          everyElement('pending'));
      expect(
        [for (final stage in story.stages) stage.at],
        everyElement(isNull),
      );
      // Three-valued: nothing has judged this one, which is a different
      // sentence from "no".
      expect(story.needsYouVerdict, isNull);
    });

    test('the thread key falls back to the progress row', () {
      final story = MessageHistory.assemble(
        source: 'email',
        sourceMessageId: 'm1',
        message: const {'subject': 'Renewal paperwork'},
        conversation: null,
        conversationAi: null,
        progress: const {'conversation_key': 'c-from-progress'},
        row: null,
        work: const [],
        memberships: const [],
        blocks: const [],
        activity: const [],
        threshold: 0.5,
      );

      expect(story.conversationKey, 'c-from-progress');
    });
  });
}
