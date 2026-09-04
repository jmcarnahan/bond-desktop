import 'dart:typed_data';

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() async {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key, {
    String state = 'waiting',
    String? lastMessageAt = '2026-08-28T10:00:00Z',
    String? subject,
  }) async {
    await store.upsertConversation({
      'conversation_key': key,
      'subject': subject ?? key,
      'state': state,
      'last_message_at': lastMessageAt,
    });
  }

  Future<void> seedMessage(
    String key,
    String id, {
    required String receivedAt,
    String? subject,
  }) async {
    await store.upsertMessage({
      'source_message_id': id,
      'conversation_key': key,
      'direction': 'inbound',
      'received_at': receivedAt,
      'subject': subject ?? key,
      'body_text': 'body of $id',
    });
  }

  Future<String> seedStoryline(
    String id, {
    String title = 'Website redesign',
    String? summary,
    String status = 'suggested',
    String createdBy = 'auto',
    String? memberHash,
    String? clusterHash,
  }) async {
    await store.insertStoryline(
      id: id,
      title: title,
      summary: summary,
      status: status,
      createdBy: createdBy,
      memberHash: memberHash,
      clusterHash: clusterHash,
    );
    return id;
  }

  group('insert and read', () {
    test('a fresh storyline reads back with its defaults', () async {
      await seedStoryline('sl-1', summary: 'Waiting on the homepage copy.');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.id, 'sl-1');
      expect(storyline.title, 'Website redesign');
      expect(storyline.summary, 'Waiting on the homepage copy.');
      expect(storyline.status, 'suggested');
      expect(storyline.createdBy, 'auto');
      expect(storyline.titleLocked, isFalse);
      expect(storyline.pinned, isFalse);
      expect(storyline.lastActivityAt, isNull);
      expect(storyline.memberCount, 0);
      expect(storyline.openCount, 0);
    });

    test('an unknown id is null rather than a throw', () async {
      expect(await store.getStoryline('sl-nope'), isNull);
    });
  });

  group('loadStorylines', () {
    test('counts members and the open ones among them', () async {
      await seedConversation('c1', state: 'needs_reply');
      await seedConversation('c2', state: 'waiting');
      await seedConversation('c3', state: 'needs_reply');
      await seedStoryline('sl-1', status: 'active');
      for (final key in ['c1', 'c2', 'c3']) {
        await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
      }

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.memberCount, 3);
      expect(storyline.openCount, 2);
    });

    test('a member whose conversation row is missing still counts as a member',
        () async {
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'gone', addedBy: 'auto');

      final storyline = (await store.loadStorylines()).single;
      expect(storyline.memberCount, 1);
      expect(storyline.openCount, 0);
    });

    test('suggestions come first, then active by recent activity', () async {
      await seedStoryline('sl-active-old', status: 'active');
      await seedStoryline('sl-active-new', status: 'active');
      await seedStoryline('sl-suggested', status: 'suggested');
      await store.touchStorylineActivity(
          'sl-active-old', '2026-08-01T00:00:00Z');
      await store.touchStorylineActivity(
          'sl-active-new', '2026-08-28T00:00:00Z');

      expect(
        (await store.loadStorylines()).map((s) => s.id).toList(),
        ['sl-suggested', 'sl-active-new', 'sl-active-old'],
      );
    });

    test('only the statuses asked for come back', () async {
      await seedStoryline('sl-1', status: 'suggested');
      await seedStoryline('sl-2', status: 'dismissed');
      await seedStoryline('sl-3', status: 'active');

      expect((await store.loadStorylines()).map((s) => s.id), ['sl-1', 'sl-3']);
      expect(
        (await store.loadStorylines(statuses: const ['dismissed']))
            .map((s) => s.id),
        ['sl-2'],
      );
      expect(await store.loadStorylines(statuses: const []), isEmpty);
    });
  });

  group('updateStoryline', () {
    test('writes only the fields it was handed', () async {
      await seedStoryline('sl-1', summary: 'the original summary');

      await store.updateStoryline('sl-1', status: 'active');

      final storyline = (await store.getStoryline('sl-1'))!;
      expect(storyline.status, 'active');
      expect(storyline.title, 'Website redesign');
      // The sentinel's whole job: an omitted summary is not a cleared one.
      expect(storyline.summary, 'the original summary');
    });

    test('an explicit null summary clears it', () async {
      await seedStoryline('sl-1', summary: 'the original summary');

      await store.updateStoryline('sl-1', summary: null);

      expect((await store.getStoryline('sl-1'))!.summary, isNull);
    });

    test('flags round-trip as 0/1 integers', () async {
      await seedStoryline('sl-1');

      await store.updateStoryline('sl-1', titleLocked: true, pinned: true);
      expect((await store.getStoryline('sl-1'))!.titleLocked, isTrue);
      expect((await store.getStoryline('sl-1'))!.pinned, isTrue);

      await store.updateStoryline('sl-1', titleLocked: false);
      expect((await store.getStoryline('sl-1'))!.titleLocked, isFalse);
      expect((await store.getStoryline('sl-1'))!.pinned, isTrue);
    });
  });

  group('members', () {
    test('adding is idempotent and keeps the first evidence', () async {
      await seedStoryline('sl-1');

      await store.addStorylineMember('sl-1', 'email', 'c1',
          addedBy: 'auto', evidence: 'same homepage copy');
      await store.addStorylineMember('sl-1', 'email', 'c1',
          addedBy: 'user', evidence: 'second thoughts');

      final member = (await store.membersOf('sl-1')).single;
      expect(member.conversationKey, 'c1');
      expect(member.addedBy, 'auto');
      expect(member.evidence, 'same homepage copy');
    });

    test('removing with block records the block', () async {
      await seedStoryline('sl-1');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);

      expect(await store.membersOf('sl-1'), isEmpty);
      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isTrue);
    });

    test('removing without block records nothing', () async {
      await seedStoryline('sl-1');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      await store.removeStorylineMember('sl-1', 'email', 'c1', block: false);

      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
    });

    test('an explicit add un-blocks', () async {
      await seedStoryline('sl-1');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);

      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'user');

      expect(await store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
      expect((await store.membersOf('sl-1')).single.addedBy, 'user');
    });

    test('a block on one storyline says nothing about another', () async {
      await seedStoryline('sl-1');
      await seedStoryline('sl-2');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);

      expect(await store.isMemberBlocked('sl-2', 'email', 'c1'), isFalse);
    });

    test('blockedThreadsOf lists this storyline\'s blocks, source included',
        () async {
      await seedStoryline('sl-1');
      await seedStoryline('sl-2');
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      await store.removeStorylineMember('sl-1', 'teams', 'chat-1', block: true);
      await store.removeStorylineMember('sl-2', 'email', 'c2', block: true);

      expect(
        await store.blockedThreadsOf('sl-1'),
        {'email\nc1', 'teams\nchat-1'},
      );
      expect(await store.blockedThreadsOf('sl-3'), isEmpty);
    });
  });

  group('storylineIdsFor', () {
    test('lists the live storylines a thread is in', () async {
      await seedStoryline('sl-1', status: 'active');
      await seedStoryline('sl-2', status: 'suggested');
      await seedStoryline('sl-3', status: 'dismissed');
      for (final id in ['sl-1', 'sl-2', 'sl-3']) {
        await store.addStorylineMember(id, 'email', 'c1', addedBy: 'auto');
      }

      expect(await store.storylineIdsFor('email', 'c1'), ['sl-1', 'sl-2']);
    });

    test('is empty for a thread in nothing', () async {
      expect(await store.storylineIdsFor('email', 'c1'), isEmpty);
    });
  });

  group('assignedOrBlockedKeys', () {
    test('unions members and blocks of live storylines only', () async {
      await seedStoryline('sl-live', status: 'active');
      await seedStoryline('sl-dead', status: 'dismissed');
      await store.addStorylineMember('sl-live', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-live', 'email', 'c2', addedBy: 'auto');
      await store.removeStorylineMember('sl-live', 'email', 'c2', block: true);
      await store.addStorylineMember('sl-dead', 'email', 'c3', addedBy: 'auto');

      // c1 is a member, c2 is blocked, c3 belongs only to a dismissed
      // storyline and is therefore free again.
      expect(await store.assignedOrBlockedKeys('email'), {'c1', 'c2'});
    });
  });

  group('dismissedHashExistsAny', () {
    test('finds a dismissed storyline by its member hash', () async {
      await seedStoryline('sl-1', status: 'dismissed', memberHash: 'h1');
      await seedStoryline('sl-2', status: 'suggested', memberHash: 'h2');

      expect(await store.dismissedHashExistsAny(['h1']), isTrue);
      // Still on screen, so not something to skip re-proposing.
      expect(await store.dismissedHashExistsAny(['h2']), isFalse);
      expect(await store.dismissedHashExistsAny(['h3']), isFalse);
    });

    test('finds a dismissed storyline by its cluster hash alone', () async {
      // The tombstone shape: a cluster that never became a suggestion has a
      // cluster hash and no members at all.
      await seedStoryline('sl-1', status: 'dismissed', clusterHash: 'c1');

      expect(await store.dismissedHashExistsAny(['c1']), isTrue);
      expect(await store.dismissedHashExistsAny(['h1']), isFalse);
    });

    test('finds a dismissed storyline by its member hash alone', () async {
      // The drifted shape read the other way round: membership moved after the
      // proposal, so the two hashes name different sets and each has to answer
      // for itself.
      await seedStoryline(
        'sl-1',
        status: 'dismissed',
        memberHash: 'h1',
        clusterHash: 'c1',
      );

      expect(await store.dismissedHashExistsAny(['h1']), isTrue);
      expect(await store.dismissedHashExistsAny(['c1']), isTrue);
    });

    test('a live storyline answers for neither hash', () async {
      await seedStoryline(
        'sl-1',
        status: 'suggested',
        memberHash: 'h1',
        clusterHash: 'c1',
      );
      await seedStoryline(
        'sl-2',
        status: 'active',
        memberHash: 'h2',
        clusterHash: 'c2',
      );

      for (final hash in ['h1', 'c1', 'h2', 'c2']) {
        expect(await store.dismissedHashExistsAny([hash]), isFalse,
            reason: '$hash belongs to a storyline still on screen');
      }
    });

    test('any one of the hashes offered is enough', () async {
      // How the caller asks about a candidate set under both hash recipes at
      // once: the current one, which folds the connector into every member,
      // and the one older tombstones were written under and can never be
      // rewritten to.
      await seedStoryline('sl-1', status: 'dismissed', clusterHash: 'old');

      expect(await store.dismissedHashExistsAny(['new', 'old']), isTrue);
      expect(await store.dismissedHashExistsAny(['old', 'new']), isTrue);
      expect(await store.dismissedHashExistsAny(['new', 'newer']), isFalse);
    });

    test('nothing asked about is nothing dismissed', () async {
      await seedStoryline('sl-1', status: 'dismissed', clusterHash: 'c1');

      expect(await store.dismissedHashExistsAny(const []), isFalse);
    });
  });

  group('blockedStorylineIdsFor', () {
    test('names only the storylines that block this thread', () async {
      await seedStoryline('sl-1');
      await seedStoryline('sl-2');
      await seedStoryline('sl-3');
      await store.removeStorylineMember('sl-1', 'email', 'c1', block: true);
      await store.removeStorylineMember('sl-3', 'email', 'c1', block: true);
      await store.removeStorylineMember('sl-2', 'email', 'c2', block: true);

      expect(await store.blockedStorylineIdsFor('email', 'c1'),
          {'sl-1', 'sl-3'});
      expect(await store.blockedStorylineIdsFor('email', 'c2'), {'sl-2'});
      expect(await store.blockedStorylineIdsFor('email', 'c9'), isEmpty);
    });

    test('a block is about one connector', () async {
      await seedStoryline('sl-1');
      // One key, two connectors — which is normal: the mail and chat
      // connectors mint their keys with no knowledge of each other. The user's
      // "no" was about the chat.
      await store.removeStorylineMember('sl-1', 'teams', 'shared', block: true);

      expect(await store.blockedStorylineIdsFor('teams', 'shared'), {'sl-1'});
      expect(await store.blockedStorylineIdsFor('email', 'shared'), isEmpty);
    });
  });

  group('memberContextRows', () {
    test('reads every storyline asked about in one call', () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await seedConversation('c3');
      for (final id in ['sl-1', 'sl-2', 'sl-3']) {
        await seedStoryline(id, status: 'active');
      }
      await seedStoryline('sl-other', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-2', 'email', 'c2', addedBy: 'auto');
      await store.addStorylineMember('sl-3', 'teams', 'c3', addedBy: 'auto');
      await store.addStorylineMember('sl-other', 'email', 'c1',
          addedBy: 'auto');

      final rows = await store.memberContextRows(
        const ['sl-1', 'sl-2', 'sl-3'],
        embedModel: 'model-a',
      );

      expect(
        {
          for (final row in rows)
            row['storyline_id']: '${row['source']}\n${row['conversation_key']}',
        },
        {'sl-1': 'email\nc1', 'sl-2': 'email\nc2', 'sl-3': 'teams\nc3'},
      );
      expect(await store.memberContextRows(const [], embedModel: 'model-a'),
          isEmpty);
    });

    test('carries the participants and the vector of each member', () async {
      await store.upsertConversation({
        'conversation_key': 'c1',
        'subject': 'Homepage copy',
        'participants_json': '[{"name":"Sarah Chen"}]',
      });
      await store.upsertConversationAi('email', 'c1',
          embedding: Uint8List.fromList(const [1, 2, 3, 4]),
          embedModel: 'model-a');
      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      final row = (await store.memberContextRows(
        const ['sl-1'],
        embedModel: 'model-a',
      ))
          .single;

      expect(row['participants_json'], '[{"name":"Sarah Chen"}]');
      expect(row['embedding'], Uint8List.fromList(const [1, 2, 3, 4]));
    });

    test('a member with no comparable vector is still a member', () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await store.upsertConversationAi('email', 'c1',
          embedding: Uint8List.fromList(const [1, 2, 3, 4]),
          embedModel: 'model-a');
      // A vector from a different generation, and a member whose conversation
      // row is gone entirely. Neither can be compared against anything, and
      // both are still filed here — a caller that lost them would offer the
      // user a thread the storyline already holds.
      await store.upsertConversationAi('email', 'c2',
          embedding: Uint8List.fromList(const [1, 2, 3, 4]),
          embedModel: 'model-b');
      await seedStoryline('sl-1', status: 'active');
      for (final key in ['c1', 'c2', 'gone']) {
        await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
      }

      final rows = await store.memberContextRows(
        const ['sl-1'],
        embedModel: 'model-a',
      );

      expect(rows.map((r) => r['conversation_key']), ['c1', 'c2', 'gone']);
      expect(rows[0]['embedding'], isNotNull);
      expect(rows[1]['embedding'], isNull);
      expect(rows[2]['embedding'], isNull);
      // No conversation row, so nobody is on it — and no row of its own to
      // drop the membership from the answer.
      expect(rows[2]['participants_json'], isNull);
    });
  });

  group('touchStorylineActivity', () {
    test('only ever moves forward', () async {
      await seedStoryline('sl-1');

      await store.touchStorylineActivity('sl-1', '2026-08-20T00:00:00Z');
      expect((await store.getStoryline('sl-1'))!.lastActivityAt,
          '2026-08-20T00:00:00Z');

      // An older thread joining must not make a live storyline look stale.
      await store.touchStorylineActivity('sl-1', '2026-08-01T00:00:00Z');
      expect((await store.getStoryline('sl-1'))!.lastActivityAt,
          '2026-08-20T00:00:00Z');

      await store.touchStorylineActivity('sl-1', '2026-08-29T00:00:00Z');
      expect((await store.getStoryline('sl-1'))!.lastActivityAt,
          '2026-08-29T00:00:00Z');
    });
  });

  group('requeueWork', () {
    Future<String?> statusOf(String kind, String id) async {
      final counts = await db.customSelect(
        'SELECT status FROM work_items WHERE task_kind = ? AND entity_id = ?',
        variables: [Variable(kind), Variable(id)],
      ).get();
      return counts.isEmpty ? null : counts.first.data['status'] as String?;
    }

    test('queues something never queued before', () async {
      await store.requeueWork('storyline', 'email', 'c1');
      expect(await statusOf('storyline', 'c1'), 'pending');
    });

    test('revives done and error', () async {
      await store.enqueueWork('storyline', 'email', 'c1');
      await store.writeWork('storyline', 'email', 'c1', status: 'done');
      await store.enqueueWork('storyline', 'email', 'c2');
      await store.writeWork('storyline', 'email', 'c2',
          status: 'error', error: 'boom', attempts: 2);

      await store.requeueWork('storyline', 'email', 'c1');
      await store.requeueWork('storyline', 'email', 'c2');

      expect(await statusOf('storyline', 'c1'), 'pending');
      expect(await statusOf('storyline', 'c2'), 'pending');
    });

    test('leaves pending and processing exactly as they are', () async {
      await store.enqueueWork('storyline', 'email', 'c1');
      await store.enqueueWork('storyline', 'email', 'c2');
      await store.writeWork('storyline', 'email', 'c2', status: 'processing');

      await store.requeueWork('storyline', 'email', 'c1');
      await store.requeueWork('storyline', 'email', 'c2');

      expect(await statusOf('storyline', 'c1'), 'pending');
      // The claim a running worker holds. Resetting it would hand the item to
      // a second drain.
      expect(await statusOf('storyline', 'c2'), 'processing');
    });

    test('a revived item keeps its place rather than duplicating', () async {
      await store.enqueueWork('storyline', 'email', 'c1');
      await store.writeWork('storyline', 'email', 'c1', status: 'done');

      await store.requeueWork('storyline', 'email', 'c1');

      expect(await store.workCounts('storyline'), {'pending': 1});
    });
  });

  group('storylineTimeline', () {
    test('merges two threads into one chronology', () async {
      await seedConversation('c1');
      await seedConversation('c2');
      await seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      await seedMessage('c2', 'm2', receivedAt: '2026-08-01T10:00:00Z');
      await seedMessage('c1', 'm3', receivedAt: '2026-08-01T11:00:00Z');
      // Not a member — it must not appear.
      await seedConversation('c9');
      await seedMessage('c9', 'm9', receivedAt: '2026-08-01T09:30:00Z');

      await seedStoryline('sl-1', status: 'active');
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

      final rows = await store.storylineTimeline('sl-1');
      expect(rows.map((r) => r['source_message_id']), ['m1', 'm2', 'm3']);
      expect(rows.map((r) => r['conversation_key']), ['c1', 'c2', 'c1']);
      expect(rows.first['subject'], 'c1');
    });

    test('an empty storyline has an empty timeline', () async {
      await seedStoryline('sl-1', status: 'active');
      expect(await store.storylineTimeline('sl-1'), isEmpty);
      expect(await store.storylineTimeline('sl-1', sources: const []), isEmpty);
    });
  });

  group('conversationsWithEmbeddings', () {
    test('returns only rows with a vector from the model asked for', () async {
      await seedConversation('c1', lastMessageAt: '2026-08-03T00:00:00Z');
      await seedConversation('c2', lastMessageAt: '2026-08-02T00:00:00Z');
      await seedConversation('c3', lastMessageAt: '2026-08-01T00:00:00Z');
      await store.upsertConversationAi('email', 'c1',
          embedding: Uint8List.fromList(const [0, 0, 0, 0]),
          embedModel: 'model-a');
      // A vector from a different generation. Comparing it against c1 would
      // produce a number with no meaning.
      await store.upsertConversationAi('email', 'c2',
          embedding: Uint8List.fromList(const [0, 0, 0, 0]),
          embedModel: 'model-b');
      // Queued but never embedded.
      await store.upsertConversationAi('email', 'c3', embedModel: 'model-a');

      final rows =
          await store.conversationsWithEmbeddings(embedModel: 'model-a');
      expect(rows.map((r) => r['conversation_key']), ['c1']);
      expect(rows.single['subject'], 'c1');
      expect(rows.single['state'], 'waiting');
      expect(rows.single['last_message_at'], '2026-08-03T00:00:00Z');
    });
  });
}
