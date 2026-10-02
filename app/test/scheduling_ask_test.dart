import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/calendar/scheduling_ask.dart';
import 'package:bond_inbox/services/decision/decision_heads.dart';
import 'package:bond_inbox/services/decision/decision_policy.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_decision_client.dart';
import 'fixtures/test_db.dart';

/// Which threads are asking for a time: the decision model's intent head at
/// `booleanYes`, a thread that still needs a reply, and nothing the owner
/// wrote since — all through [schedulingAskKeys], the one path the app and
/// these tests share, over ONE store query. Fixture times come from the
/// clock.
void main() {
  const dana = 'dana@fabrikam.example';
  const owner = 'me@contoso.example';

  late BondDatabase db;
  late MessageStore store;
  late DateTime now;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    now = DateTime.now().toUtc();
  });

  tearDown(() async {
    await db.close();
  });

  String ago(Duration d) => MessageStore.isoStamp(now.subtract(d));

  /// One thread with one inbound message [age] ago and a decision on it.
  /// [outboundAfter] gives the thread a `last_outbound_at` that long AFTER
  /// the inbound message (negative: before it), as the send fold writes it.
  Future<void> thread(
    String key, {
    String state = 'needs_reply',
    String intent = 'scheduling',
    double p = 0.9,
    bool decided = true,
    Duration? outboundAfter,
    Duration age = const Duration(hours: 2),
  }) async {
    final outAt = outboundAfter == null ? null : ago(age - outboundAfter);
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Thread $key',
      'participants_json':
          '[{"name":"Dana","email":"$dana"},{"name":"Me","email":"$owner"}]',
      'state': state,
      'message_count': outAt == null ? 1 : 2,
      'last_inbound_at': ago(age),
      'last_outbound_at': ?outAt,
      'last_message_at': ago(age),
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'in-$key',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Thread $key',
      'from_name': 'Dana',
      'from_address': dana,
      'received_at': ago(age),
      'body_text': 'Can we find a time next week?',
      'triage_status': 'done',
    });
    if (decided) {
      await store.writeDecision(
        'email',
        'in-$key',
        fakeDecision(fakeAnswers(intent: intent, choiceP: p)),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );
    }
  }

  Future<Set<String>> keys({int limit = 200}) =>
      schedulingAskKeys(store, limit: limit);

  test('a needs-reply thread whose newest inbound mail asks for a time',
      () async {
    await thread('c-1');
    expect(await keys(), {'email|c-1'});
  });

  test('scheduling at p booleanYes is an ask; just under it is not',
      () async {
    expect(DecisionPolicy.booleanYes, 0.5);
    await thread('c-at', p: 0.5);
    await thread('c-under', p: 0.49);
    expect(await keys(), {'email|c-at'});
  });

  test('another intent, no decision, or an unreadable one is not an ask',
      () async {
    await thread('c-other', intent: 'question');
    await thread('c-none', decided: false);
    await thread('c-bad');
    await db.customUpdate(
      'UPDATE message_decisions SET answers_json = ? '
      'WHERE source_message_id = ?',
      variables: [Variable('{not json'), Variable('in-c-bad')],
    );
    await thread('c-good');
    expect(await keys(), {'email|c-good'},
        reason: 'an unreadable row is no ask, and fails nothing else');
  });

  test('an intent answer without per-option probabilities is read by its '
      'confidence', () async {
    await thread('c-conf');
    await db.customUpdate(
      'UPDATE message_decisions SET answers_json = ? '
      'WHERE source_message_id = ?',
      variables: [
        Variable('{"intent":{"choice":"scheduling","confidence":0.7}}'),
        Variable('in-c-conf'),
      ],
    );
    expect(await keys(), {'email|c-conf'});
  });

  test('a done or waiting thread is not an ask', () async {
    await thread('c-done', state: 'done');
    await thread('c-wait', state: 'waiting');
    expect(await keys(), isEmpty);
  });

  test('the owner wrote after the newest inbound message: answered, not an '
      'ask', () async {
    await thread('c-out', outboundAfter: const Duration(minutes: 5));
    // Written BEFORE the ask: the ask still stands.
    await thread('c-before', outboundAfter: const Duration(minutes: -5));
    expect(await keys(), {'email|c-before'});
  });

  test('only the NEWEST inbound message counts', () async {
    await thread('c-2');
    // A later message on the same thread that is not about a time.
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'in-c-2-later',
      'conversation_key': 'c-2',
      'direction': 'inbound',
      'subject': 'Thread c-2',
      'from_name': 'Dana',
      'from_address': dana,
      'received_at': ago(const Duration(hours: 1)),
      'body_text': 'Also, the numbers are attached.',
      'triage_status': 'done',
    });
    await store.writeDecision(
      'email',
      'in-c-2-later',
      fakeDecision(fakeAnswers(intent: 'fyi', choiceP: 0.9)),
      qhash: DecisionHeads.expectedQhash,
      ownerKnown: true,
    );
    expect(await keys(), isEmpty);
  });

  test('the keys read the newest threads first, at most limit', () async {
    await thread('c-old', age: const Duration(hours: 5));
    await thread('c-new', age: const Duration(hours: 1));
    expect(await keys(limit: 1), {'email|c-new'});
    expect(await keys(), {'email|c-old', 'email|c-new'});
  });

  group('the owner closing an ask', () {
    /// A second inbound message on [key], [age] ago, read as [intent].
    Future<void> laterMessage(String key, String id,
        {String intent = 'scheduling', Duration age = const Duration(hours: 1)}) async {
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': id,
        'conversation_key': key,
        'direction': 'inbound',
        'subject': 'Thread $key',
        'from_name': 'Dana',
        'from_address': dana,
        'received_at': ago(age),
        'body_text': 'That time does not work for me — another?',
        'triage_status': 'done',
      });
      await store.writeDecision(
        'email',
        id,
        fakeDecision(fakeAnswers(intent: intent, choiceP: 0.9)),
        qhash: DecisionHeads.expectedQhash,
        ownerKnown: true,
      );
    }

    Future<int> label(String key, String messageId,
            {String origin = 'dismiss', String? createdAt}) =>
        store.writeSchedulingAskLabel(
          source: 'email',
          conversationKey: key,
          sourceMessageId: messageId,
          origin: origin,
          createdAt: createdAt,
        );

    test('the rows carry the newest inbound message id', () async {
      await thread('c-1');
      expect(await schedulingAskMessageIds(store), {'email|c-1': 'in-c-1'});
    });

    test('a label on the newest inbound message closes the ask', () async {
      await thread('c-1');
      await thread('c-2');
      await label('c-1', 'in-c-1', origin: 'invite');
      expect(await keys(), {'email|c-2'});
    });

    test('a label on an older message does not', () async {
      await thread('c-1', age: const Duration(hours: 3));
      await label('c-1', 'in-c-1');
      await laterMessage('c-1', 'in-c-1-later');
      expect(await schedulingAskMessageIds(store),
          {'email|c-1': 'in-c-1-later'});
    });

    test('a newer inbound message after a label opens the ask again',
        () async {
      await thread('c-1', age: const Duration(hours: 3));
      await label('c-1', 'in-c-1');
      expect(await keys(), isEmpty);
      await laterMessage('c-1', 'in-c-1-later');
      expect(await keys(), {'email|c-1'});
    });

    test('the label is deleted by id AND stamp, and the ask is back',
        () async {
      await thread('c-1');
      const stamp = '2026-10-02T12:00:00.000000Z';
      final id = await label('c-1', 'in-c-1', createdAt: stamp);
      expect(await keys(), isEmpty);
      expect(await store.deleteSchedulingAskLabel(id, createdAt: 'other'),
          isFalse);
      expect(await keys(), isEmpty);
      expect(await store.deleteSchedulingAskLabel(id, createdAt: stamp),
          isTrue);
      expect(await keys(), {'email|c-1'});
    });

    test('the Needs You readers never see a scheduling_ask row', () async {
      await thread('c-1');
      await label('c-1', 'in-c-1');
      expect(await store.needsYouLabels(), isEmpty);
      expect(await store.needsYouLabelSignature(), (count: 0, maxId: 0));
      expect(await store.needsYouPressCounts(), (removed: 0, added: 0));
      expect(await store.deleteAllNeedsYouLabels(), 0);
      expect(await store.decisionLabels(), hasLength(1));
    });
  });
}
