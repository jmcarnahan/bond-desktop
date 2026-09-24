// `show BondDatabase`: drift generates row classes named Label and
// ConversationLabel from the two tables, and this file means the app's own
// models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The owner's vocabulary: the CRUD behind the picker and the Settings list,
/// and the join that puts its words on an inbox row.
///
/// Two rules run through all of it. A label is the OWNER'S word — nothing here
/// touches `messages.label`, the model's verdict — and `use_count` is a
/// popularity signal rather than a refcount, which is why removing a label from
/// a thread leaves the count where it was.

void main() {
  late BondDatabase db;
  late MessageStore store;

  /// A stamp [n] hours back. Derived from now rather than written out, because
  /// a literal date in a fixture rots the day a window walks past it.
  String ago(int hours) =>
      MessageStore.isoStamp(DateTime.now().toUtc().subtract(Duration(hours: hours)));

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedConversation(
    String key, {
    String source = 'email',
    String subject = 'Access to the analytics tool',
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': subject,
      'state': 'needs_reply',
      'last_message_at': ago(2),
    });
  }

  /// One label's stored row, straight out of the table.
  Future<Map<String, Object?>> rowOf(String id) async {
    final row = await db
        .customSelect(
          'SELECT * FROM labels WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingle();
    return row.data;
  }

  Future<int> linkCount() async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS n FROM conversation_labels')
        .getSingle();
    return (row.data['n'] as num).toInt();
  }

  group('createLabel', () {
    test('mints a slug id, a name key and an unused count', () async {
      final label = await store.createLabel('FYI only');

      expect(label.name, 'FYI only');
      expect(label.id, startsWith('fyi-only-'));
      expect(label.useCount, 0);
      expect(label.lastUsedAt, isNull);
      expect(label.tone, isNull);
      expect((await rowOf(label.id))['name_key'], 'fyi only');
    });

    test('is idempotent over casing and stray space', () async {
      final first = await store.createLabel('Meeting response');
      final again = await store.createLabel('  meeting RESPONSE ');

      // The picker's Enter key means "file this under this word". A person
      // typing a name that already exists means the chip they can see.
      expect(again.id, first.id);
      expect(again.name, 'Meeting response');
      final all = await store.listLabels();
      expect(all, hasLength(1));
    });

    test('keeps the tone the label already had', () async {
      final first = await store.createLabel('Handled elsewhere',
          tone: 'success');
      final again = await store.createLabel('handled elsewhere', tone: 'error');

      expect(again.id, first.id);
      expect((await rowOf(first.id))['tone'], 'success');
    });

    test('two different names that slug alike are two labels', () async {
      final plain = await store.createLabel('FYI only');
      final punctuated = await store.createLabel('FYI, only!');

      expect(punctuated.id, isNot(plain.id));
      expect(punctuated.id, startsWith('fyi-only-'));
      expect(await store.listLabels(), hasLength(2));
    });

    test('a name with nothing slug-able still gets an id', () async {
      final label = await store.createLabel('🚀');

      expect(label.id, startsWith('label-'));
      expect(label.name, '🚀');
    });

    test('the name key is unique in the database, not just in the method',
        () async {
      final label = await store.createLabel('Not for me');

      // The index is what makes the idempotent create safe under a race: two
      // presses in the same millisecond cannot leave two rows behind.
      await expectLater(
        db.customUpdate(
          'INSERT INTO labels (id, name, name_key, use_count, created_at, '
          'updated_at) VALUES (?, ?, ?, 0, ?, ?)',
          variables: [
            Variable('not-for-me-ffff'),
            Variable('Not for me'),
            Variable('not for me'),
            Variable(ago(0)),
            Variable(ago(0)),
          ],
        ),
        throwsA(anything),
      );
      expect(await store.listLabels(), hasLength(1));
      expect((await store.listLabels()).single.id, label.id);
    });
  });

  group('renameLabel', () {
    test('keeps the id, so the threads it is on come with it', () async {
      final label = await store.createLabel('Jira update');
      await seedConversation('c1');
      await store.applyLabels('email', 'c1', [label.id]);

      await store.renameLabel(label.id, 'Tracker noise');

      final row = await rowOf(label.id);
      expect(row['name'], 'Tracker noise');
      expect(row['name_key'], 'tracker noise');
      final onThread = await store.labelsForConversation('email', 'c1');
      expect(onThread.single.id, label.id);
      expect(onThread.single.name, 'Tracker noise');
    });

    test('refuses to merge two labels', () async {
      final first = await store.createLabel('FYI only');
      final second = await store.createLabel('Later');

      // Create is "apply the one that exists"; a rename onto an existing name
      // would move threads the owner never mentioned.
      expect(
        () => store.renameLabel(second.id, 'fyi ONLY'),
        throwsA(isA<StateError>()),
      );
      expect((await rowOf(second.id))['name'], 'Later');
      expect((await rowOf(first.id))['name'], 'FYI only');
    });

    test('re-spelling a label as itself goes through', () async {
      final label = await store.createLabel('fyi only');

      await store.renameLabel(label.id, 'FYI Only');

      expect((await rowOf(label.id))['name'], 'FYI Only');
    });

    test('trims what it stores', () async {
      final label = await store.createLabel('Later');

      await store.renameLabel(label.id, '  Waiting on legal  ');

      expect((await rowOf(label.id))['name'], 'Waiting on legal');
      expect((await rowOf(label.id))['name_key'], 'waiting on legal');
    });
  });

  group('setLabelTone', () {
    test('sets a tone and clears it again', () async {
      final label = await store.createLabel('Deadline');

      await store.setLabelTone(label.id, 'attention');
      expect((await rowOf(label.id))['tone'], 'attention');

      await store.setLabelTone(label.id, null);
      expect((await rowOf(label.id))['tone'], isNull);
    });
  });

  group('deleteLabel', () {
    test('takes its links with it and leaves the others alone', () async {
      final doomed = await store.createLabel('Not for me');
      final kept = await store.createLabel('FYI only');
      await seedConversation('c1');
      await seedConversation('c2');
      await store.applyLabels('email', 'c1', [doomed.id, kept.id]);
      await store.applyLabels('email', 'c2', [doomed.id]);
      expect(await linkCount(), 3);

      await store.deleteLabel(doomed.id);

      expect(await linkCount(), 1);
      expect(
        (await store.labelsForConversation('email', 'c1')).single.id,
        kept.id,
      );
      expect(await store.labelsForConversation('email', 'c2'), isEmpty);
      expect((await store.listLabels()).single.id, kept.id);
    });
  });

  group('listLabels', () {
    test('most used, then most recent, then alphabetical', () async {
      final popular = await store.createLabel('FYI only');
      final recent = await store.createLabel('Later');
      final stale = await store.createLabel('Handled elsewhere');
      final unusedB = await store.createLabel('Not for me');
      final unusedA = await store.createLabel('Ask again');

      // Written by hand rather than by applying labels in order: the two
      // one-use labels have to be a known number of hours apart for the
      // recency tie-break to be the thing under test.
      Future<void> used(String id, int count, String at) => db.customUpdate(
            'UPDATE labels SET use_count = ?, last_used_at = ? WHERE id = ?',
            variables: [Variable(count), Variable(at), Variable(id)],
          );
      await used(popular.id, 9, ago(50));
      await used(recent.id, 1, ago(1));
      await used(stale.id, 1, ago(30));

      expect(
        [for (final l in await store.listLabels()) l.id],
        [popular.id, recent.id, stale.id, unusedA.id, unusedB.id],
      );
    });
  });

  group('applyLabels', () {
    test('links the thread and records that the word was reached for',
        () async {
      final fyi = await store.createLabel('FYI only');
      final later = await store.createLabel('Later');
      await seedConversation('c1');

      await store.applyLabels('email', 'c1', [fyi.id, later.id]);

      final stored = await rowOf(fyi.id);
      expect(stored['use_count'], 1);
      expect(stored['last_used_at'], isNotNull);
      expect(stored['last_used_at'], stored['updated_at']);
      expect(await linkCount(), 2);
      final link = await db
          .customSelect(
            'SELECT * FROM conversation_labels WHERE label_id = ?',
            variables: [Variable(fyi.id)],
          )
          .getSingle();
      expect(link.data['applied_by'], 'user');
    });

    test('applying one twice is one chip and two reaches', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('c1');

      await store.applyLabels('email', 'c1', [fyi.id]);
      final firstUse = (await rowOf(fyi.id))['last_used_at'] as String;
      await store.applyLabels('email', 'c1', [fyi.id]);

      expect(await linkCount(), 1);
      // The count still moves: the owner did reach for the word again.
      expect((await rowOf(fyi.id))['use_count'], 2);
      // Compared with `compareTo`: these stamps sort lexicographically by
      // construction (`MessageStore.isoStamp`), and the ordering matchers
      // reach for `<`, which a String does not have.
      final secondUse = (await rowOf(fyi.id))['last_used_at'] as String;
      expect(secondUse.compareTo(firstUse), greaterThanOrEqualTo(0));
    });

    test('a rule-applied link says so', () async {
      final fyi = await store.createLabel('Meeting response');
      await seedConversation('c1');

      await store.applyLabels('email', 'c1', [fyi.id], appliedBy: 'rule');

      final link = await db
          .customSelect('SELECT * FROM conversation_labels')
          .getSingle();
      expect(ConversationLabel.fromRow(link.data).isRule, isTrue);
    });

    test('an empty list writes nothing at all', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('c1');

      await store.applyLabels('email', 'c1', const []);

      expect(await linkCount(), 0);
      expect((await rowOf(fyi.id))['use_count'], 0);
    });

    test('the same key under two connectors is two threads', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('shared');
      await seedConversation('shared', source: 'teams');

      await store.applyLabels('teams', 'shared', [fyi.id]);

      expect(await store.labelsForConversation('teams', 'shared'),
          hasLength(1));
      expect(await store.labelsForConversation('email', 'shared'), isEmpty);
    });
  });

  group('removeLabel', () {
    test('drops the link and leaves the popularity where it was', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('c1');
      await store.applyLabels('email', 'c1', [fyi.id]);

      await store.removeLabel('email', 'c1', fyi.id);

      expect(await linkCount(), 0);
      // A count that fell would quietly demote a chip because of one
      // correction. It is how often the word was reached for, not a refcount.
      expect((await rowOf(fyi.id))['use_count'], 1);
      expect((await rowOf(fyi.id))['last_used_at'], isNotNull);
    });

    test('removing what was never applied changes nothing', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('c1');

      await store.removeLabel('email', 'c1', fyi.id);

      expect(await linkCount(), 0);
      expect((await rowOf(fyi.id))['use_count'], 0);
    });
  });

  group('labelsForConversation', () {
    test('most-used first, and nothing from another thread', () async {
      final fyi = await store.createLabel('FYI only');
      final later = await store.createLabel('Later');
      await seedConversation('c1');
      await seedConversation('c2');
      await store.applyLabels('email', 'c2', [later.id]);
      await store.applyLabels('email', 'c2', [later.id]);
      await store.applyLabels('email', 'c1', [fyi.id, later.id]);

      expect(
        [for (final l in await store.labelsForConversation('email', 'c1')) l.id],
        [later.id, fyi.id],
      );
      expect(
        [for (final l in await store.labelsForConversation('email', 'c2')) l.id],
        [later.id],
      );
    });

    test('a thread nobody filed reads empty', () async {
      await seedConversation('c1');
      expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    });
  });

  group('the loadConversations join', () {
    test('puts the owner\'s words on the row, most used first', () async {
      final fyi = await store.createLabel('FYI only', tone: 'success');
      final later = await store.createLabel('Later');
      await seedConversation('c1');
      await store.applyLabels('email', 'c1', [fyi.id]);
      await store.applyLabels('email', 'c1', [fyi.id, later.id]);

      final row =
          (await store.loadConversations(sources: const ['email'])).single;

      expect([for (final l in row.labels) l.name], ['FYI only', 'Later']);
      expect(row.labels.first.id, fyi.id);
      expect(row.labels.first.tone, 'success');
      // The tone is a word, and an absent one arrives as null rather than ''.
      expect(row.labels.last.tone, isNull);
    });

    test('a thread with no labels reads as an empty list', () async {
      await seedConversation('c1');

      final row =
          (await store.loadConversations(sources: const ['email'])).single;

      expect(row.labels, isEmpty);
    });

    test('a comma in a name survives the round trip', () async {
      // The whole reason the separators are control characters: this is a
      // perfectly good label name.
      final label = await store.createLabel('Waiting on legal, then finance');
      await seedConversation('c1');
      await store.applyLabels('email', 'c1', [label.id]);

      final row =
          (await store.loadConversations(sources: const ['email'])).single;

      expect(row.labels.single.name, 'Waiting on legal, then finance');
    });

    test('a separator character in a name costs that label and no other',
        () async {
      // Nothing on this platform can type one, so this is the paranoid case.
      // What it must not do is shift the fields of every label after it.
      final odd = await store.createLabel(
        'Odd${labelFieldSeparator}name${labelRecordSeparator}two',
      );
      final plain = await store.createLabel('Later');
      await seedConversation('c1');
      await store.applyLabels('email', 'c1', [plain.id]);
      await store.applyLabels('email', 'c1', [plain.id, odd.id]);

      final row =
          (await store.loadConversations(sources: const ['email'])).single;

      // The sane label is intact and keeps its own id, which is what a chip
      // and a facet are keyed on.
      final sane = row.labels.where((l) => l.id == plain.id);
      expect(sane, hasLength(1));
      expect(sane.single.name, 'Later');
      expect(sane.single.tone, isNull);
      // And the odd one degraded into its own entries rather than corrupting
      // the list: the reader is bounded, so nothing bleeds across labels.
      expect(row.labels.map((l) => l.id), contains(odd.id));
    });

    test('the join is scoped by connector as well as by key', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('shared');
      await seedConversation('shared', source: 'teams');
      await store.applyLabels('teams', 'shared', [fyi.id]);

      final mail =
          (await store.loadConversations(sources: const ['email'])).single;
      final chat =
          (await store.loadConversations(sources: const ['teams'])).single;

      expect(mail.labels, isEmpty);
      expect(chat.labels.single.id, fyi.id);
    });

    test('a deleted label takes its chip off the row', () async {
      final fyi = await store.createLabel('FYI only');
      await seedConversation('c1');
      await store.applyLabels('email', 'c1', [fyi.id]);

      await store.deleteLabel(fyi.id);

      final row =
          (await store.loadConversations(sources: const ['email'])).single;
      expect(row.labels, isEmpty);
    });

    test('the counts beside it are still one thread\'s worth', () async {
      // The join is a GROUP_CONCAT over a subselect and not a real join, so
      // three labels must not triple the unread count next to them.
      await seedConversation('c1');
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'm1',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'received_at': ago(2),
        'is_read': 0,
      });
      for (final name in ['FYI only', 'Later', 'Not for me']) {
        final label = await store.createLabel(name);
        await store.applyLabels('email', 'c1', [label.id]);
      }

      final row =
          (await store.loadConversations(sources: const ['email'])).single;

      expect(row.labels, hasLength(3));
      expect(row.unreadCount, 1);
    });
  });
}
