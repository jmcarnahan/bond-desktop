import 'dart:async';
import 'dart:typed_data';

// `show`: drift generates an `ActivityEvent` row class from the
// `activity_events` table, and this file means the log's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/activity_log.dart';
import 'package:bond_inbox/services/drain_gate.dart';
import 'package:bond_inbox/services/gate_repair_service.dart';
import 'package:bond_inbox/services/storyline_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/scripted_llm.dart';
import 'fixtures/test_db.dart';

/// A store whose kept-count throws, for the one test about failing soft.
class BrokenStore extends MessageStore {
  BrokenStore(super.db);

  @override
  Future<int> keptInboundCount(String source, String conversationKey) async =>
      throw StateError('the database went away');
}

/// What a gate that speaks late undoes.
///
/// The property under all of it: a conversation with nothing kept in it is a
/// thread the app must stop describing. Its vector is out of the clustering
/// corpus, its automatic storyline memberships are gone with a block that says
/// why, and the filing that was queued for it never runs. What the repair must
/// NOT do is as load-bearing — no audit, and never a membership the owner
/// filed by hand.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  GateRepairService serviceOn(MessageStore on, {DrainGate? storylineGate}) =>
      GateRepairService(
        on,
        // A client that would throw if anything dialled it. Nothing here
        // does: a repair is store work, and a model call in it would be a bug
        // this fixture turns into a failure.
        StorylineService(on, ScriptedLlm.never(label: 'the repair')),
        activityLog: ActivityLog(on),
        storylineGate: storylineGate,
      );

  GateRepairService service() => serviceOn(store);

  /// Waits for whatever this gate is already holding, and nothing else.
  ///
  /// [DrainGate] is a FIFO chain, and `afterGate` queues the storyline half
  /// synchronously before its own future completes — so a body handed over
  /// afterwards is strictly behind that repair, and awaiting it is awaiting
  /// the repair. A `Future.delayed` here would be a guess about how long the
  /// store takes.
  Future<void> fence(DrainGate gate) => gate.run(() async {});

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  Future<void> seedMessage({
    required String id,
    String source = 'email',
    String conversationKey = 'conv-1',
    String direction = 'inbound',
    String triageStatus = 'skipped',
    String? gateReason = 'no_reply',
  }) async {
    await store.upsertMessage({
      'source': source,
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': direction,
      'subject': 'Launch date',
      'from_name': 'Sarah Chen',
      'from_address': 'sarah@example.com',
      'received_at': '2026-08-28T10:00:00Z',
      'body_text': 'Body of $id',
      'triage_status': triageStatus,
      'gate_reason': gateReason,
    });
  }

  Future<void> seedEmbedded(String key, {String source = 'email'}) =>
      store.upsertConversationAi(
        source,
        key,
        embedding: bytes([1, 2, 3, 4]),
        embeddedHash: 'h-$key',
        embedModel: 'model-a',
      );

  Future<void> seedStoryline(
    String id, {
    String key = 'conv-1',
    String addedBy = 'auto',
  }) async {
    await store.insertStoryline(
      id: id,
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
      memberHash: 'stale-hash',
    );
    await store.addStorylineMember(
      id,
      'email',
      key,
      addedBy: addedBy,
      evidence: 'Both concern the website redesign.',
    );
    await store.updateStoryline(
      id,
      recapText: 'The studio is reviewing the homepage copy.',
      recapThrough: '2026-08-28T10:00:00Z',
    );
  }

  Future<List<ActivityEvent>> activity() async => [
        for (final row in await store.recentActivity(limit: 10))
          ActivityEvent.fromRow(row),
      ];

  Future<ActivityEvent?> repairRow() async {
    final rows = await activity();
    final found = rows.where((e) => e.kind == 'gate_repair');
    return found.isEmpty ? null : found.first;
  }

  group('the storyline lane', () {
    test('a repair issued mid-drain runs after that drain', () async {
      await seedMessage(id: 'm1');
      await seedEmbedded('conv-1');
      await seedStoryline('sl-1');
      await store.enqueueWork('storyline', 'email', 'conv-1');

      // The lane, busy. Until the drains were split this could not happen:
      // `afterGate` runs inside the triage drain, which held the one gate the
      // storyline passes also took.
      final gate = DrainGate();
      final sweeping = Completer<void>();
      final swept = gate.run(() => sweeping.future);

      final repaired =
          serviceOn(store, storylineGate: gate).afterGate(
        'email',
        'm1',
        reason: 'extracted_then_gated',
      );

      // The message side is answered immediately — the triage drain awaits
      // this, and must not wait minutes behind a sweep.
      final outcome = await repaired;
      expect(outcome.allGated, isTrue);
      // Nothing storyline-side has moved yet: the lane still holds the gate.
      expect(await store.membersOf('sl-1'), hasLength(1));
      expect(await store.workStatusOf('storyline', 'email', 'conv-1'),
          'pending');

      sweeping.complete();
      await swept;
      await fence(gate);

      expect(await store.membersOf('sl-1'), isEmpty);
      expect((await store.getConversationAi('email', 'conv-1'))!['embedding'],
          isNull);
      // The sharp one: a delete that landed while the lane held this row's
      // claim would have missed it, and the assign pass would have filed the
      // thread straight back after the eviction.
      expect(await store.workStatusOf('storyline', 'email', 'conv-1'), isNull);
    });

    test('the deferred half writes its own row', () async {
      await seedMessage(id: 'm1');
      await seedEmbedded('conv-1');
      await seedStoryline('sl-1');

      final gate = DrainGate();
      await serviceOn(store, storylineGate: gate)
          .afterGate('email', 'm1', reason: 'ignored');
      await fence(gate);

      final event = (await repairRow())!;
      expect(event.detail['reason'], 'ignored');
      expect(event.detail['storylines'], 1);
      expect(event.detail['embedding_cleared'], isTrue);
    });

    test('with no gate it is inline, exactly as it always was', () async {
      await seedMessage(id: 'm1');
      await seedEmbedded('conv-1');
      await seedStoryline('sl-1');

      // Every test in this file that predates the lane takes this path, and
      // so does any build without a storyline worker: the counts come back on
      // the outcome, awaited.
      final outcome =
          await service().afterGate('email', 'm1', reason: 'ignored');

      expect(outcome.storylines, 1);
      expect(outcome.embeddingCleared, isTrue);
      expect(await store.membersOf('sl-1'), isEmpty);
    });
  });

  group('afterGate', () {
    test('an all-gated thread loses its memberships, its vector and its '
        'queued filing', () async {
      await seedMessage(id: 'm1');
      await seedEmbedded('conv-1');
      await seedStoryline('sl-1');
      await store.enqueueWork('storyline', 'email', 'conv-1');

      final outcome = await service()
          .afterGate('email', 'm1', reason: 'extracted_then_gated');

      expect(outcome.allGated, isTrue);
      expect(outcome.storylines, 1);
      expect(outcome.embeddingCleared, isTrue);
      expect(outcome.pendingWorkDeleted, 1);
      expect(outcome.extracted, isFalse);

      expect(await store.membersOf('sl-1'), isEmpty);
      final block = (await store.blocksOf('sl-1')).single;
      // A gate's own "no", and its own sentence: the block says why the
      // thread left, not what the model thought when it filed it.
      expect(block.blockedBy, 'gate');
      expect(block.evidence, 'every inbound message in this thread was gated');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.recapText, isNull);
      expect(storyline.recapThrough, isNull);
      expect(storyline.memberHash, isNot('stale-hash'));

      // The refresh, because the group describes something smaller now. And
      // deliberately NO audit: a gate says nothing about the model's
      // reasoning, so there is no lesson to spread.
      expect(await store.workStatusOf('storyline_refresh', 'email', 'sl-1'),
          'pending');
      expect(
          await store.workStatusOf('storyline_audit', 'email', 'sl-1'), isNull);

      final ai = (await store.getConversationAi('email', 'conv-1'))!;
      expect(ai['embedding'], isNull);
      expect(ai['embedded_hash'], isNull);
      expect(ai['embed_model'], isNull);

      expect(await store.workStatusOf('storyline', 'email', 'conv-1'), isNull);

      final event = (await repairRow())!;
      expect(event.entityId, 'm1');
      expect(event.source, 'email');
      expect(event.count, 1);
      expect(event.detail['reason'], 'extracted_then_gated');
      expect(event.detail['storylines'], 1);
      expect(event.detail['embedding_cleared'], isTrue);
      expect(event.detail['extracted'], 0);
      expect(event.detail['conversation_key'], 'conv-1');
    });

    test('a membership the owner filed by hand is left alone', () async {
      await seedMessage(id: 'm1');
      await seedStoryline('sl-1', addedBy: 'user');

      final outcome =
          await service().afterGate('email', 'm1', reason: 'ignored');

      // A gate does not overrule a person.
      expect(outcome.storylines, 0);
      expect((await store.membersOf('sl-1')).single.addedBy, 'user');
      expect(await store.blocksOf('sl-1'), isEmpty);
    });

    test('a thread with a kept inbound left keeps everything', () async {
      await seedMessage(id: 'bulk');
      await seedMessage(id: 'real', triageStatus: 'triaged', gateReason: null);
      await seedEmbedded('conv-1');
      await seedStoryline('sl-1');

      final outcome = await service()
          .afterGate('email', 'bulk', reason: 'extracted_then_gated');

      expect(outcome.allGated, isFalse);
      expect(await store.membersOf('sl-1'), hasLength(1));
      expect((await store.getConversationAi('email', 'conv-1'))!['embedding'],
          isNotNull);
      // Nothing moved and nothing was extracted: a gate on an ordinary
      // newsletter is the common case and must write no row.
      expect(await repairRow(), isNull);
    });

    test('a message the model had already read is counted even when nothing '
        'moves', () async {
      await seedMessage(id: 'bulk');
      await seedMessage(id: 'real', triageStatus: 'triaged', gateReason: null);
      await store.writeExtraction('email', 'bulk', '{"evidence":"read"}');

      final outcome = await service()
          .afterGate('email', 'bulk', reason: 'extracted_then_gated');

      expect(outcome.extracted, isTrue);
      expect(outcome.allGated, isFalse);
      final event = (await repairRow())!;
      expect(event.count, 0);
      expect(event.detail['extracted'], 1);
      expect(event.detail['storylines'], 0);
      expect(event.detail['embedding_cleared'], isFalse);
    });

    test("the owner's Ignore says so on the row", () async {
      await seedMessage(id: 'm1');
      await seedEmbedded('conv-1');

      await service().afterGate('email', 'm1', reason: 'ignored');

      expect((await repairRow())!.detail['reason'], 'ignored');
    });

    test('nothing stored under the keys is nothing done and nothing said',
        () async {
      final outcome =
          await service().afterGate('email', 'ghost', reason: 'ignored');

      expect(outcome, same(GateRepairOutcome.nothing));
      expect(await activity(), isEmpty);
    });

    test('a store that fails costs the repair, never the caller', () async {
      final broken = BrokenStore(db);
      await seedMessage(id: 'm1');

      final outcome =
          await serviceOn(broken).afterGate('email', 'm1', reason: 'ignored');

      expect(outcome.allGated, isFalse);
      expect(await activity(), isEmpty);
    });
  });

  group('repairAll', () {
    test('walks the all-gated threads and reports what history left',
        () async {
      // Two all-gated threads carrying vectors: the sweep's whole business.
      await seedMessage(id: 'g1', conversationKey: 'conv-1');
      await seedEmbedded('conv-1');
      await seedStoryline('sl-1');
      await store.writeExtraction('email', 'g1', '{"a":1}');
      await seedMessage(id: 'g2', conversationKey: 'conv-2');
      await seedEmbedded('conv-2');
      // One kept thread with a vector, which stays exactly as it is.
      await seedMessage(
        id: 'k1',
        conversationKey: 'conv-3',
        triageStatus: 'triaged',
        gateReason: null,
      );
      await seedEmbedded('conv-3');
      // All gated and never embedded: nothing to take back, so not counted.
      await seedMessage(id: 'g3', conversationKey: 'conv-4');

      expect(await service().repairAll(), (repaired: 2, complete: true));

      expect((await store.getConversationAi('email', 'conv-1'))!['embedding'],
          isNull);
      expect((await store.getConversationAi('email', 'conv-2'))!['embedding'],
          isNull);
      expect((await store.getConversationAi('email', 'conv-3'))!['embedding'],
          isNotNull);
      expect(await store.membersOf('sl-1'), isEmpty);

      final event = (await repairRow())!;
      expect(event.detail['reason'], 'one_shot');
      expect(event.detail['conversations'], 2);
      expect(event.detail['storylines'], 1);
      expect(event.detail['embeddings_cleared'], 2);
      // The joined count off the tables, not a tally this pass kept.
      expect(event.detail['extracted'], 1);
      expect(event.count, 1);
    });

    test('an outbound-only thread is not this repair\'s business', () async {
      await seedMessage(
        id: 's1',
        conversationKey: 'conv-1',
        direction: 'outbound',
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );
      await seedEmbedded('conv-1');

      expect((await service().repairAll()).repaired, 0);

      // "Every inbound in this thread was gated" is not true of a thread with
      // no inbound at all — the user wrote to somebody and nobody answered.
      expect((await store.getConversationAi('email', 'conv-1'))!['embedding'],
          isNotNull);
    });

    test('a message with no thread key is counted and nothing else', () async {
      // The one path that stops before the kept-count: there is no thread to
      // ask about. The counter is still owed when the model had read it.
      await seedMessage(id: 'e1', conversationKey: '');
      await store.writeExtraction('email', 'e1', '{"a":1}');

      final outcome =
          await service().afterGate('email', 'e1', reason: 'ignored');

      expect(outcome.allGated, isFalse);
      expect(outcome.extracted, isTrue);
      final event = (await repairRow())!;
      expect(event.count, 0);
      expect(event.detail['extracted'], 1);
      expect(event.detail['reason'], 'ignored');
    });

    test('a chat born skipped under teams_source is kept, so never repaired',
        () async {
      // The edge `keptMessageSql` exists for: a legacy chat's `skipped`
      // records a pipeline that did not exist yet, not a verdict about the
      // words. Its thread keeps its vector and its filing, on both paths.
      await seedMessage(
        id: 'c1',
        source: 'teams',
        conversationKey: 'chat-1',
        triageStatus: 'skipped',
        gateReason: 'teams_source',
      );
      await seedEmbedded('chat-1', source: 'teams');
      await store.enqueueWork('storyline', 'teams', 'chat-1');

      final outcome = await service().afterGate(
        'teams',
        'c1',
        reason: 'extracted_then_gated',
      );
      expect(outcome.allGated, isFalse);
      expect((await service().repairAll()).repaired, 0);

      expect((await store.getConversationAi('teams', 'chat-1'))!['embedding'],
          isNotNull);
      expect(await store.workStatusOf('storyline', 'teams', 'chat-1'),
          'pending');
    });

    test('a full slice is not the end of the sweep', () async {
      for (var i = 1; i <= 3; i++) {
        await seedMessage(id: 'g$i', conversationKey: 'conv-$i');
        await seedEmbedded('conv-$i');
      }

      // Two of three: a full slice, so the caller keeps the one-shot owed.
      expect(await service().repairAll(cap: 2), (repaired: 2, complete: false));
      expect((await repairRow())!.detail['capped'], 2);

      // The remaining one, short of the cap: done.
      expect(await service().repairAll(cap: 2), (repaired: 1, complete: true));
      for (var i = 1; i <= 3; i++) {
        expect(
          (await store.getConversationAi('email', 'conv-$i'))!['embedding'],
          isNull,
        );
      }
    });

    test('a one-shot that found a clean database still says so', () async {
      expect(await service().repairAll(), (repaired: 0, complete: true));

      final event = (await repairRow())!;
      expect(event.detail['conversations'], 0);
      expect(event.detail['storylines'], 0);
    });
  });
}
