// `show BondDatabase`: drift generates a row class named Label from the labels
// table, and this file means the app's own model.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/providers/labels_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The notifier behind the picker and the Settings list.
///
/// Two house rules are what these tests are really about: **once loaded, never
/// blank** — a failed re-read keeps the chips that are drawn — and a refusal
/// arrives as a sentence in the state rather than as a throw, because there is
/// no dialog anywhere in this app to catch one.

/// A store whose reads start working and then stop, for the stale-list rule.
class FlakyStore extends MessageStore {
  FlakyStore(super.db);

  bool failReads = false;

  /// Links refused, for the bool that says whether a label went on or off.
  bool failWrites = false;

  @override
  Future<List<Label>> listLabels() async {
    if (failReads) throw StateError('disk is full');
    return super.listLabels();
  }

  @override
  Future<void> applyLabels(
    String source,
    String conversationKey,
    List<String> labelIds, {
    String appliedBy = 'user',
  }) async {
    if (failWrites) throw StateError('disk is full');
    return super.applyLabels(
      source,
      conversationKey,
      labelIds,
      appliedBy: appliedBy,
    );
  }

  @override
  Future<bool> removeLabel(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    if (failWrites) throw StateError('disk is full');
    return super.removeLabel(source, conversationKey, labelId);
  }

  @override
  Future<bool> restoreLabel(
    String source,
    String conversationKey,
    String labelId,
  ) async {
    if (failWrites) throw StateError('disk is full');
    return super.restoreLabel(source, conversationKey, labelId);
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  test('a first load arrives loaded, in the picker\'s order', () async {
    final popular = await store.createLabel('FYI only');
    final unused = await store.createLabel('Ask again');
    await store.applyLabels('email', 'c1', [popular.id]);
    final notifier = LabelsNotifier(store);

    expect(notifier.state.loaded, isFalse);
    await notifier.load();

    expect(notifier.state.loaded, isTrue);
    // Most used first, which is the order every surface shows.
    expect(
      [for (final l in notifier.state.labels) l.id],
      [popular.id, unused.id],
    );
    expect(notifier.state.error, isNull);
  });

  test('a store with no labels is loaded and empty, not unloaded', () async {
    final notifier = LabelsNotifier(store);

    await notifier.load();

    // The two empty lists a picker has to draw differently: nothing read yet
    // is a moment, no labels yet is an invitation.
    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.labels, isEmpty);
  });

  test('a failed re-read keeps the chips and hangs a sentence off them',
      () async {
    final flaky = FlakyStore(db);
    await flaky.createLabel('FYI only');
    final notifier = LabelsNotifier(flaky);
    await notifier.load();

    flaky.failReads = true;
    await notifier.load();

    // A picker that emptied itself mid-keystroke reads as "your labels are
    // gone", which is the one thing a failed read must not say.
    expect(notifier.state.labels, hasLength(1));
    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.error, contains('last list'));

    flaky.failReads = false;
    await notifier.load();
    expect(notifier.state.error, isNull);
  });

  test('create hands back the label and refreshes the list', () async {
    final notifier = LabelsNotifier(store);
    await notifier.load();

    final label = await notifier.create('FYI only', tone: 'success');

    expect(label, isNotNull);
    expect(label!.name, 'FYI only');
    expect(notifier.state.labels.single.id, label.id);
  });

  test('creating a name that exists is the label that exists', () async {
    final first = await store.createLabel('Meeting response');
    final notifier = LabelsNotifier(store);
    await notifier.load();

    final again = await notifier.create('  meeting RESPONSE ');

    // What the picker's Enter key needs: a person typing a word they can
    // already see means that word.
    expect(again!.id, first.id);
    expect(notifier.state.labels, hasLength(1));
  });

  test('a blank name is not a label', () async {
    final notifier = LabelsNotifier(store);

    expect(await notifier.create('   '), isNull);
    expect(await store.listLabels(), isEmpty);
  });

  test('a rename onto another word is refused under the field', () async {
    await store.createLabel('FYI only');
    final later = await store.createLabel('Later');
    final notifier = LabelsNotifier(store);
    await notifier.load();

    final ok = await notifier.rename(later.id, 'fyi ONLY');

    // A refusal rather than a silent merge, and a sentence rather than a
    // throw: the Settings list has nowhere to catch one.
    expect(ok, isFalse);
    expect(notifier.state.error, isNotNull);
    expect(notifier.state.labels, hasLength(2));
  });

  test('a rename that goes through clears the sentence before it', () async {
    final later = await store.createLabel('Later');
    final notifier = LabelsNotifier(store);
    await notifier.load();
    await notifier.create('FYI only');
    await notifier.rename(later.id, 'FYI only');
    expect(notifier.state.error, isNotNull);

    final ok = await notifier.rename(later.id, 'Waiting on legal');

    // A sentence that could only be set and never cleared would outlive the
    // failure it described.
    expect(ok, isTrue);
    expect(notifier.state.error, isNull);
    expect(
      [for (final l in notifier.state.labels) l.name]..sort(),
      ['FYI only', 'Waiting on legal'],
    );
  });

  test('a tone change and a delete both re-read the list', () async {
    final fyi = await store.createLabel('FYI only');
    final later = await store.createLabel('Later');
    final notifier = LabelsNotifier(store);
    await notifier.load();

    await notifier.setTone(fyi.id, 'attention');
    expect(
      notifier.state.labels.firstWhere((l) => l.id == fyi.id).tone,
      'attention',
    );

    await notifier.delete(later.id);
    expect([for (final l in notifier.state.labels) l.id], [fyi.id]);
  });

  test('apply files the thread and tells the inbox to re-read', () async {
    final fyi = await store.createLabel('FYI only');
    var announced = 0;
    final notifier = LabelsNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );
    await notifier.load();

    await notifier.apply('email', 'c1', [fyi.id]);

    expect(await store.labelsForConversation('email', 'c1'), hasLength(1));
    // The chip has to land on the row in the same frame it lands in the
    // picker, and the notifier knows nothing about the row.
    expect(announced, 1);
    // An apply moves `use_count`, which is what orders the chips the owner is
    // looking at, so the list is re-read too.
    expect(notifier.state.labels.single.useCount, 1);
  });

  test('applying nothing writes nothing and announces nothing', () async {
    var announced = 0;
    final notifier = LabelsNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );
    await notifier.load();

    await notifier.apply('email', 'c1', const []);

    expect(announced, 0);
  });

  test('remove takes the word off the thread and leaves its count', () async {
    final fyi = await store.createLabel('FYI only');
    var announced = 0;
    final notifier = LabelsNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );
    await notifier.load();
    await notifier.apply('email', 'c1', [fyi.id]);

    await notifier.remove('email', 'c1', fyi.id);

    expect(await store.labelsForConversation('email', 'c1'), isEmpty);
    expect(announced, 2);
    // A count that fell would demote a chip because of one correction.
    expect((await store.listLabels()).single.useCount, 1);
  });

  test('a failing announce is not a failed write', () async {
    final fyi = await store.createLabel('FYI only');
    final notifier = LabelsNotifier(
      store,
      onThreadsChanged: () async => throw StateError('the list is gone'),
    );
    await notifier.load();

    await notifier.apply('email', 'c1', [fyi.id]);

    // The filing happened. Whether the inbox managed to redraw is the inbox's
    // business, and saying "couldn't file that" here would be a lie.
    expect(await store.labelsForConversation('email', 'c1'), hasLength(1));
    expect(notifier.state.error, isNull);
  });

  group('a write says whether it happened', () {
    test('an apply that went on says so, and one refused says no', () async {
      final flaky = FlakyStore(db);
      final fyi = await flaky.createLabel('FYI only');
      final notifier = LabelsNotifier(flaky);
      await notifier.load();

      expect(await notifier.apply('email', 'c1', [fyi.id]), isTrue);
      expect(notifier.state.error, isNull);

      flaky.failWrites = true;
      // A "Labeled" toast, and an Undo behind it, over nothing written is
      // what the bool exists to stop.
      expect(await notifier.apply('email', 'c2', [fyi.id]), isFalse);
      expect(notifier.state.error, "Couldn't file that thread just now.");
      expect(await flaky.labelsForConversation('email', 'c2'), isEmpty);
    });

    test('a remove refused says no, and the chip stays', () async {
      final flaky = FlakyStore(db);
      final fyi = await flaky.createLabel('FYI only');
      await flaky.applyLabels('email', 'c1', [fyi.id]);
      final notifier = LabelsNotifier(flaky);
      await notifier.load();

      flaky.failWrites = true;
      expect(await notifier.remove('email', 'c1', fyi.id), isNull);
      expect(notifier.state.error, "Couldn't take that label off just now.");
      expect(await flaky.labelsForConversation('email', 'c1'), hasLength(1));
    });

    test('a remove answers whether a link came off', () async {
      final flaky = FlakyStore(db);
      final fyi = await flaky.createLabel('FYI only');
      await flaky.applyLabels('email', 'c1', [fyi.id]);
      final notifier = LabelsNotifier(flaky);
      await notifier.load();

      final removal = await notifier.remove('email', 'c1', fyi.id);
      expect(removal!.removed, isTrue);

      // A second ✕ on the same chip took nothing off: the write went
      // through, but there is no link to hang an Undo on.
      final again = await notifier.remove('email', 'c1', fyi.id);
      expect(again, isNotNull);
      expect(again!.removed, isFalse);
    });

    test('a restore puts the link back uncounted, and a refused one says no',
        () async {
      final flaky = FlakyStore(db);
      final fyi = await flaky.createLabel('FYI only');
      await flaky.applyLabels('email', 'c1', [fyi.id]);
      final notifier = LabelsNotifier(flaky);
      await notifier.load();
      await notifier.remove('email', 'c1', fyi.id);

      flaky.failWrites = true;
      expect(await notifier.restore('email', 'c1', fyi.id), isFalse);
      expect(
        notifier.state.error,
        "Couldn't put that label back just now.",
      );

      flaky.failWrites = false;
      expect(await notifier.restore('email', 'c1', fyi.id), isTrue);
      expect(await flaky.labelsForConversation('email', 'c1'), hasLength(1));
      // Putting back what was there is not a second reach for the word.
      expect((await flaky.listLabels()).single.useCount, 1);
    });

    test('nothing to apply is nothing refused', () async {
      final notifier = LabelsNotifier(FlakyStore(db)..failWrites = true);

      expect(await notifier.apply('email', 'c1', const []), isTrue);
    });
  });
}
