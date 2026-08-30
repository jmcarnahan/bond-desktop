import 'dart:typed_data';

import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late MessageStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    applySchema(db);
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  void seedConversation(
    String key, {
    String state = 'waiting',
    String? lastMessageAt = '2026-08-28T10:00:00Z',
    String? subject,
  }) {
    store.upsertConversation({
      'conversation_key': key,
      'subject': subject ?? key,
      'state': state,
      'last_message_at': lastMessageAt,
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

  String seedStoryline(
    String id, {
    String title = 'Willow St purchase',
    String? summary,
    String status = 'suggested',
    String createdBy = 'auto',
    String? memberHash,
  }) {
    store.insertStoryline(
      id: id,
      title: title,
      summary: summary,
      status: status,
      createdBy: createdBy,
      memberHash: memberHash,
    );
    return id;
  }

  group('insert and read', () {
    test('a fresh storyline reads back with its defaults', () {
      seedStoryline('sl-1', summary: 'Waiting on the appraisal.');

      final storyline = store.getStoryline('sl-1')!;
      expect(storyline.id, 'sl-1');
      expect(storyline.title, 'Willow St purchase');
      expect(storyline.summary, 'Waiting on the appraisal.');
      expect(storyline.status, 'suggested');
      expect(storyline.createdBy, 'auto');
      expect(storyline.titleLocked, isFalse);
      expect(storyline.pinned, isFalse);
      expect(storyline.lastActivityAt, isNull);
      expect(storyline.memberCount, 0);
      expect(storyline.openCount, 0);
    });

    test('an unknown id is null rather than a throw', () {
      expect(store.getStoryline('sl-nope'), isNull);
    });
  });

  group('loadStorylines', () {
    test('counts members and the open ones among them', () {
      seedConversation('c1', state: 'needs_reply');
      seedConversation('c2', state: 'waiting');
      seedConversation('c3', state: 'needs_reply');
      seedStoryline('sl-1', status: 'active');
      for (final key in ['c1', 'c2', 'c3']) {
        store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
      }

      final storyline = store.loadStorylines().single;
      expect(storyline.memberCount, 3);
      expect(storyline.openCount, 2);
    });

    test('a member whose conversation row is missing still counts as a member',
        () {
      seedStoryline('sl-1', status: 'active');
      store.addStorylineMember('sl-1', 'email', 'gone', addedBy: 'auto');

      final storyline = store.loadStorylines().single;
      expect(storyline.memberCount, 1);
      expect(storyline.openCount, 0);
    });

    test('suggestions come first, then active by recent activity', () {
      seedStoryline('sl-active-old', status: 'active');
      seedStoryline('sl-active-new', status: 'active');
      seedStoryline('sl-suggested', status: 'suggested');
      store.touchStorylineActivity('sl-active-old', '2026-08-01T00:00:00Z');
      store.touchStorylineActivity('sl-active-new', '2026-08-28T00:00:00Z');

      expect(
        store.loadStorylines().map((s) => s.id).toList(),
        ['sl-suggested', 'sl-active-new', 'sl-active-old'],
      );
    });

    test('only the statuses asked for come back', () {
      seedStoryline('sl-1', status: 'suggested');
      seedStoryline('sl-2', status: 'dismissed');
      seedStoryline('sl-3', status: 'active');

      expect(store.loadStorylines().map((s) => s.id), ['sl-1', 'sl-3']);
      expect(
        store.loadStorylines(statuses: const ['dismissed']).map((s) => s.id),
        ['sl-2'],
      );
      expect(store.loadStorylines(statuses: const []), isEmpty);
    });
  });

  group('updateStoryline', () {
    test('writes only the fields it was handed', () {
      seedStoryline('sl-1', summary: 'the original summary');

      store.updateStoryline('sl-1', status: 'active');

      final storyline = store.getStoryline('sl-1')!;
      expect(storyline.status, 'active');
      expect(storyline.title, 'Willow St purchase');
      // The sentinel's whole job: an omitted summary is not a cleared one.
      expect(storyline.summary, 'the original summary');
    });

    test('an explicit null summary clears it', () {
      seedStoryline('sl-1', summary: 'the original summary');

      store.updateStoryline('sl-1', summary: null);

      expect(store.getStoryline('sl-1')!.summary, isNull);
    });

    test('flags round-trip as 0/1 integers', () {
      seedStoryline('sl-1');

      store.updateStoryline('sl-1', titleLocked: true, pinned: true);
      expect(store.getStoryline('sl-1')!.titleLocked, isTrue);
      expect(store.getStoryline('sl-1')!.pinned, isTrue);

      store.updateStoryline('sl-1', titleLocked: false);
      expect(store.getStoryline('sl-1')!.titleLocked, isFalse);
      expect(store.getStoryline('sl-1')!.pinned, isTrue);
    });
  });

  group('members', () {
    test('adding is idempotent and keeps the first evidence', () {
      seedStoryline('sl-1');

      store.addStorylineMember('sl-1', 'email', 'c1',
          addedBy: 'auto', evidence: 'same appraisal');
      store.addStorylineMember('sl-1', 'email', 'c1',
          addedBy: 'user', evidence: 'second thoughts');

      final member = store.membersOf('sl-1').single;
      expect(member.conversationKey, 'c1');
      expect(member.addedBy, 'auto');
      expect(member.evidence, 'same appraisal');
    });

    test('removing with block records the block', () {
      seedStoryline('sl-1');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      store.removeStorylineMember('sl-1', 'email', 'c1', block: true);

      expect(store.membersOf('sl-1'), isEmpty);
      expect(store.isMemberBlocked('sl-1', 'email', 'c1'), isTrue);
    });

    test('removing without block records nothing', () {
      seedStoryline('sl-1');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');

      store.removeStorylineMember('sl-1', 'email', 'c1', block: false);

      expect(store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
    });

    test('an explicit add un-blocks', () {
      seedStoryline('sl-1');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      store.removeStorylineMember('sl-1', 'email', 'c1', block: true);

      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'user');

      expect(store.isMemberBlocked('sl-1', 'email', 'c1'), isFalse);
      expect(store.membersOf('sl-1').single.addedBy, 'user');
    });

    test('a block on one storyline says nothing about another', () {
      seedStoryline('sl-1');
      seedStoryline('sl-2');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      store.removeStorylineMember('sl-1', 'email', 'c1', block: true);

      expect(store.isMemberBlocked('sl-2', 'email', 'c1'), isFalse);
    });
  });

  group('storylineIdsFor', () {
    test('lists the live storylines a thread is in', () {
      seedStoryline('sl-1', status: 'active');
      seedStoryline('sl-2', status: 'suggested');
      seedStoryline('sl-3', status: 'dismissed');
      for (final id in ['sl-1', 'sl-2', 'sl-3']) {
        store.addStorylineMember(id, 'email', 'c1', addedBy: 'auto');
      }

      expect(store.storylineIdsFor('email', 'c1'), ['sl-1', 'sl-2']);
    });

    test('is empty for a thread in nothing', () {
      expect(store.storylineIdsFor('email', 'c1'), isEmpty);
    });
  });

  group('assignedOrBlockedKeys', () {
    test('unions members and blocks of live storylines only', () {
      seedStoryline('sl-live', status: 'active');
      seedStoryline('sl-dead', status: 'dismissed');
      store.addStorylineMember('sl-live', 'email', 'c1', addedBy: 'auto');
      store.addStorylineMember('sl-live', 'email', 'c2', addedBy: 'auto');
      store.removeStorylineMember('sl-live', 'email', 'c2', block: true);
      store.addStorylineMember('sl-dead', 'email', 'c3', addedBy: 'auto');

      // c1 is a member, c2 is blocked, c3 belongs only to a dismissed
      // storyline and is therefore free again.
      expect(store.assignedOrBlockedKeys('email'), {'c1', 'c2'});
    });
  });

  group('dismissedMemberHashExists', () {
    test('finds a dismissed storyline by its member hash', () {
      seedStoryline('sl-1', status: 'dismissed', memberHash: 'h1');
      seedStoryline('sl-2', status: 'suggested', memberHash: 'h2');

      expect(store.dismissedMemberHashExists('h1'), isTrue);
      // Still on screen, so not something to skip re-proposing.
      expect(store.dismissedMemberHashExists('h2'), isFalse);
      expect(store.dismissedMemberHashExists('h3'), isFalse);
    });
  });

  group('touchStorylineActivity', () {
    test('only ever moves forward', () {
      seedStoryline('sl-1');

      store.touchStorylineActivity('sl-1', '2026-08-20T00:00:00Z');
      expect(store.getStoryline('sl-1')!.lastActivityAt,
          '2026-08-20T00:00:00Z');

      // An older thread joining must not make a live storyline look stale.
      store.touchStorylineActivity('sl-1', '2026-08-01T00:00:00Z');
      expect(store.getStoryline('sl-1')!.lastActivityAt,
          '2026-08-20T00:00:00Z');

      store.touchStorylineActivity('sl-1', '2026-08-29T00:00:00Z');
      expect(store.getStoryline('sl-1')!.lastActivityAt,
          '2026-08-29T00:00:00Z');
    });
  });

  group('requeueWork', () {
    String? statusOf(String kind, String id) {
      final counts = db.select(
        'SELECT status FROM work_items WHERE task_kind = ? AND entity_id = ?',
        [kind, id],
      );
      return counts.isEmpty ? null : counts.first['status'] as String?;
    }

    test('queues something never queued before', () {
      store.requeueWork('storyline', 'email', 'c1');
      expect(statusOf('storyline', 'c1'), 'pending');
    });

    test('revives done and error', () {
      store.enqueueWork('storyline', 'email', 'c1');
      store.writeWork('storyline', 'email', 'c1', status: 'done');
      store.enqueueWork('storyline', 'email', 'c2');
      store.writeWork('storyline', 'email', 'c2',
          status: 'error', error: 'boom', attempts: 2);

      store.requeueWork('storyline', 'email', 'c1');
      store.requeueWork('storyline', 'email', 'c2');

      expect(statusOf('storyline', 'c1'), 'pending');
      expect(statusOf('storyline', 'c2'), 'pending');
    });

    test('leaves pending and processing exactly as they are', () {
      store.enqueueWork('storyline', 'email', 'c1');
      store.enqueueWork('storyline', 'email', 'c2');
      store.writeWork('storyline', 'email', 'c2', status: 'processing');

      store.requeueWork('storyline', 'email', 'c1');
      store.requeueWork('storyline', 'email', 'c2');

      expect(statusOf('storyline', 'c1'), 'pending');
      // The claim a running worker holds. Resetting it would hand the item to
      // a second drain.
      expect(statusOf('storyline', 'c2'), 'processing');
    });

    test('a revived item keeps its place rather than duplicating', () {
      store.enqueueWork('storyline', 'email', 'c1');
      store.writeWork('storyline', 'email', 'c1', status: 'done');

      store.requeueWork('storyline', 'email', 'c1');

      expect(store.workCounts('storyline'), {'pending': 1});
    });
  });

  group('storylineTimeline', () {
    test('merges two threads into one chronology', () {
      seedConversation('c1');
      seedConversation('c2');
      seedMessage('c1', 'm1', receivedAt: '2026-08-01T09:00:00Z');
      seedMessage('c2', 'm2', receivedAt: '2026-08-01T10:00:00Z');
      seedMessage('c1', 'm3', receivedAt: '2026-08-01T11:00:00Z');
      // Not a member — it must not appear.
      seedConversation('c9');
      seedMessage('c9', 'm9', receivedAt: '2026-08-01T09:30:00Z');

      seedStoryline('sl-1', status: 'active');
      store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');

      final rows = store.storylineTimeline('sl-1');
      expect(rows.map((r) => r['source_message_id']), ['m1', 'm2', 'm3']);
      expect(rows.map((r) => r['conversation_key']), ['c1', 'c2', 'c1']);
      expect(rows.first['subject'], 'c1');
    });

    test('an empty storyline has an empty timeline', () {
      seedStoryline('sl-1', status: 'active');
      expect(store.storylineTimeline('sl-1'), isEmpty);
      expect(store.storylineTimeline('sl-1', sources: const []), isEmpty);
    });
  });

  group('conversationsWithEmbeddings', () {
    test('returns only rows with a vector from the model asked for', () {
      seedConversation('c1', lastMessageAt: '2026-08-03T00:00:00Z');
      seedConversation('c2', lastMessageAt: '2026-08-02T00:00:00Z');
      seedConversation('c3', lastMessageAt: '2026-08-01T00:00:00Z');
      store.upsertConversationAi('email', 'c1',
          embedding: Uint8List.fromList(const [0, 0, 0, 0]),
          embedModel: 'model-a');
      // A vector from a different generation. Comparing it against c1 would
      // produce a number with no meaning.
      store.upsertConversationAi('email', 'c2',
          embedding: Uint8List.fromList(const [0, 0, 0, 0]),
          embedModel: 'model-b');
      // Queued but never embedded.
      store.upsertConversationAi('email', 'c3', embedModel: 'model-a');

      final rows = store.conversationsWithEmbeddings(embedModel: 'model-a');
      expect(rows.map((r) => r['conversation_key']), ['c1']);
      expect(rows.single['subject'], 'c1');
      expect(rows.single['state'], 'waiting');
      expect(rows.single['last_message_at'], '2026-08-03T00:00:00Z');
    });
  });
}
