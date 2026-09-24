// `show BondDatabase`: drift generates row classes named Label and LabelRule
// from the tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/providers/label_rules_provider.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The notifier behind the Settings rules list and the picker that writes a rule.
///
/// The same two house rules as `labels_provider_test.dart`: **once loaded, never
/// blank** — a failed re-read keeps the rules already on screen — and a refusal
/// arrives as a sentence in the state rather than as a throw, because there is no
/// dialog anywhere in this app to catch one. Plus the one this notifier adds:
/// every write answers with how many THREADS moved, because creating a rule is
/// not a settings change, it moves mail.

/// A store whose reads start working and then stop, for the stale-list rule.
class FlakyStore extends MessageStore {
  FlakyStore(super.db);

  bool failReads = false;

  @override
  Future<List<LabelRule>> listLabelRules() async {
    if (failReads) throw StateError('disk is full');
    return super.listLabelRules();
  }
}

/// A store that refuses every write, for the sentence-not-a-throw rule.
class RefusingStore extends MessageStore {
  RefusingStore(super.db);

  @override
  Future<LabelRule> createLabelRule({
    required String labelId,
    required String scopeKind,
    required String scopeValue,
    required String disposition,
    bool unlessMentionsMe = true,
  }) async =>
      throw StateError('A rule needs something to match on');

  @override
  Future<int> undoLabelRule(String ruleId) async => throw Exception('no disk');
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  String ago(int hours) => MessageStore.isoStamp(
      DateTime.now().toUtc().subtract(Duration(hours: hours)));

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedMessage(
    String id, {
    String conversationKey = 'c1',
    String from = 'alerts@tracker.example.com',
    String subject = 'Quarterly planning',
  }) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': conversationKey,
      'subject': subject,
      'state': 'needs_reply',
      'last_message_at': ago(2),
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': id,
      'conversation_key': conversationKey,
      'direction': 'inbound',
      'subject': subject,
      'from_address': from,
      'received_at': ago(2),
      'is_read': 0,
    });
  }

  test('a first load arrives loaded, newest rule first', () async {
    final label = await store.createLabel('Not for me');
    final older = await store.createLabelRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );
    await db.customUpdate(
      'UPDATE label_rules SET created_at = ? WHERE id = ?',
      variables: [Variable(ago(48)), Variable(older.id)],
    );
    final newer = await store.createLabelRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeDomain,
      scopeValue: 'vendor.example.com',
      disposition: LabelRule.sendToLater,
    );
    final notifier = LabelRulesNotifier(store);

    expect(notifier.state.loaded, isFalse);
    await notifier.load();

    expect(notifier.state.loaded, isTrue);
    expect([for (final r in notifier.state.rules) r.id], [newer.id, older.id]);
    expect(notifier.state.error, isNull);
  });

  test('a store with no rules is loaded and empty, not unloaded', () async {
    final notifier = LabelRulesNotifier(store);

    await notifier.load();

    // The two empty lists a Settings list has to draw differently: nothing read
    // yet is a moment, no rules yet is an invitation.
    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.rules, isEmpty);
  });

  test('a failed re-read keeps the rules and hangs a sentence off them',
      () async {
    final flaky = FlakyStore(db);
    final label = await flaky.createLabel('Not for me');
    await flaky.createLabelRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );
    final notifier = LabelRulesNotifier(flaky);
    await notifier.load();

    flaky.failReads = true;
    await notifier.load();

    // A list of standing instructions that emptied itself reads as "your rules
    // are gone", which is alarming in a way no spinner justifies.
    expect(notifier.state.rules, hasLength(1));
    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.error, isNotNull);
  });

  test('creating a rule files the mail already here and says how much',
      () async {
    await seedMessage('m1', conversationKey: 'c1');
    await seedMessage('m2', conversationKey: 'c2');
    final label = await store.createLabel('Not for me');
    var announced = 0;
    final notifier = LabelRulesNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );

    final moved = await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );

    expect(moved, 2);
    // The list is re-read by the write, so the surface never has to.
    expect(notifier.state.rules, hasLength(1));
    expect(notifier.state.rules.single.hiddenCount, 2);
    expect(notifier.state.error, isNull);
    expect(announced, 1);
  });

  test('a rule that matches nothing is still written, and moves nothing',
      () async {
    await seedMessage('m1', from: 'alex@example.com');
    final label = await store.createLabel('Not for me');
    var announced = 0;
    final notifier = LabelRulesNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );

    final moved = await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );

    // Zero is a real answer, which is why null is what failure looks like.
    expect(moved, 0);
    expect(notifier.state.rules, hasLength(1));
    // Nothing moved, so nothing asks the inbox to re-read.
    expect(announced, 0);
  });

  test('a blank scope is refused before the store is asked', () async {
    final label = await store.createLabel('Not for me');
    final notifier = LabelRulesNotifier(store);

    final moved = await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSubject,
      scopeValue: '   ',
      disposition: LabelRule.sendToLater,
    );

    expect(moved, isNull);
    expect(await store.listLabelRules(), isEmpty);
  });

  test('a refused write becomes a sentence, never a throw', () async {
    final refusing = RefusingStore(db);
    final label = await refusing.createLabel('Not for me');
    final notifier = LabelRulesNotifier(refusing);

    final moved = await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );

    expect(moved, isNull);
    expect(notifier.state.error, 'A rule needs something to match on');
  });

  test('a lookback bounds what a new rule reaches', () async {
    await seedMessage('m1', conversationKey: 'c1');
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'old',
      'conversation_key': 'c2',
      'direction': 'inbound',
      'subject': 'Quarterly planning',
      'from_address': 'alerts@tracker.example.com',
      'received_at': ago(96),
      'is_read': 0,
    });
    final label = await store.createLabel('Not for me');
    final notifier = LabelRulesNotifier(store, lookbackIso: ago(24));

    expect(
      await notifier.createRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeSender,
        scopeValue: 'alerts@tracker.example.com',
        disposition: LabelRule.hideNeedsYou,
      ),
      1,
    );
  });

  test('a classifier handed in is what wakes a classification rule', () async {
    await seedMessage('m1', subject: 'Accepted: Quarterly planning');
    final label = await store.createLabel('Meeting response');
    final notifier = LabelRulesNotifier(
      store,
      classify: (row) =>
          (row['subject'] as String? ?? '').startsWith('Accepted:')
              ? 'meeting_response'
              : null,
    );

    expect(
      await notifier.createRule(
        labelId: label.id,
        scopeKind: LabelRule.scopeClassification,
        scopeValue: 'meeting_response',
        disposition: LabelRule.hideNeedsYou,
      ),
      1,
    );
  });

  test('correcting a rule replaces it rather than refusing', () async {
    final quiet = await store.createLabel('Not for me');
    final later = await store.createLabel('Later');
    final notifier = LabelRulesNotifier(store);

    await notifier.createRule(
      labelId: quiet.id,
      scopeKind: LabelRule.scopeDomain,
      scopeValue: 'vendor.example.com',
      disposition: LabelRule.hideNeedsYou,
    );
    await notifier.createRule(
      labelId: later.id,
      scopeKind: LabelRule.scopeDomain,
      scopeValue: 'vendor.example.com',
      disposition: LabelRule.sendToLater,
    );

    expect(notifier.state.rules, hasLength(1));
    expect(notifier.state.rules.single.disposition, LabelRule.sendToLater);
    expect(notifier.state.error, isNull);
  });

  test('deleting a rule stops it without moving any thread back', () async {
    await seedMessage('m1');
    final label = await store.createLabel('Not for me');
    var announced = 0;
    final notifier = LabelRulesNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );
    await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );
    announced = 0;

    await notifier.deleteRule(notifier.state.rules.single.id);

    expect(notifier.state.rules, isEmpty);
    expect(announced, 0);
    // The thread the owner has stopped thinking about stays filed.
    expect(
      (await store.getMessageRow('email', 'm1'))!['needs_you_verdict'],
      0,
    );
  });

  test('undo takes the rule back and announces the threads it returned',
      () async {
    await seedMessage('m1');
    final label = await store.createLabel('Not for me');
    var announced = 0;
    final notifier = LabelRulesNotifier(
      store,
      onThreadsChanged: () async => announced++,
    );
    await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );
    announced = 0;

    final moved = await notifier.undoRule(notifier.state.rules.single.id);

    expect(moved, 1);
    expect(notifier.state.rules, isEmpty);
    expect(announced, 1);
    expect(
      (await store.getMessageRow('email', 'm1'))!['needs_you_verdict'],
      isNull,
    );
  });

  test('a failed undo becomes a sentence and leaves the rule standing',
      () async {
    final refusing = RefusingStore(db);
    final label = await refusing.createLabel('Not for me');
    // Written through the store rather than the notifier, whose create this
    // double refuses.
    final rule = await MessageStore(db).createLabelRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );
    final notifier = LabelRulesNotifier(refusing);

    expect(await notifier.undoRule(rule.id), isNull);

    expect(notifier.state.error, isNotNull);
    expect(await MessageStore(db).listLabelRules(), hasLength(1));
  });

  test('a list refresh that fails after a good write keeps the write',
      () async {
    await seedMessage('m1');
    final flaky = FlakyStore(db);
    final label = await flaky.createLabel('Not for me');
    final notifier = LabelRulesNotifier(flaky);

    // The apply has to have happened even though the re-read after it did not:
    // a rule reported as failed invites a second press that writes it twice.
    flaky.failReads = true;
    final moved = await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );

    expect(moved, 1);
    expect(notifier.state.error, isNotNull);
    flaky.failReads = false;
    await notifier.load();
    expect(notifier.state.rules, hasLength(1));
    expect(notifier.state.error, isNull);
  });

  test('a thread refresh that throws is not the reason a write failed',
      () async {
    await seedMessage('m1');
    final label = await store.createLabel('Not for me');
    final notifier = LabelRulesNotifier(
      store,
      onThreadsChanged: () async => throw Exception('the list is busy'),
    );

    final moved = await notifier.createRule(
      labelId: label.id,
      scopeKind: LabelRule.scopeSender,
      scopeValue: 'alerts@tracker.example.com',
      disposition: LabelRule.hideNeedsYou,
    );

    expect(moved, 1);
    expect(notifier.state.rules, hasLength(1));
    expect(notifier.state.error, isNull);
  });
}
