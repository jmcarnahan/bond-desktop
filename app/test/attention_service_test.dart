import 'dart:convert';
import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/attention.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

void main() {
  late BondDatabase db;
  late MessageStore store;
  late AttentionService service;

  /// Pinned so the recency decay is the same on every run.
  final now = DateTime.utc(2026, 8, 29, 12);
  const String justNow = '2026-08-29T11:00:00Z';

  /// What a message [justNow] — one hour before [now] — is multiplied by.
  /// Small, but it is why the scores below are not round numbers.
  final decay = math.exp(-math.ln2 * (1 / 24) / AttentionTuning.recencyHalfLifeDays);

  /// Both sources, for the tests that seed a Teams thread. The default is
  /// email-only, the same as production's mail-only configuration.
  const both = ['email', 'teams'];

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    service = AttentionService(store);
  });

  tearDown(() async => db.close());

  /// One thread with one inbound message and, optionally, an extraction on it.
  ///
  /// [replyExpected] null is the important default: it leaves the message
  /// untriaged, which is how the columns read for every thread that predates
  /// triage v2. Passing either value writes a triage result and puts the
  /// message on the judged side of that line.
  Future<void> seed(
    String key, {
    String source = 'email',
    String state = 'waiting',
    String from = 'eric@x.com',
    String? intent,
    String? importance,
    String receivedAt = justNow,
    String? ctaText,
    bool addressedMe = false,
    bool? replyExpected,
    bool needsAction = false,
    String deadline = '',
    bool answered = false,
  }) async {
    await store.upsertConversation({
      'source': source,
      'conversation_key': key,
      'subject': key,
      'state': state,
      'cta_text': ctaText,
      'last_message_at': receivedAt,
      'last_inbound_at': receivedAt,
    });
    await store.upsertMessage({
      'source': source,
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'from_address': from,
      'received_at': receivedAt,
      'addressed_me': addressedMe ? 1 : 0,
    });
    if (answered) {
      await store.upsertMessage({
        'source': source,
        'source_message_id': '$key-out',
        'conversation_key': key,
        'direction': 'outbound',
        'from_address': 'me@x.com',
        'received_at': receivedAt,
      });
    }
    if (replyExpected != null) {
      await store.writeTriage(
        source,
        '$key-m1',
        status: 'done',
        result: TriageResult(
          urgency: 'normal',
          category: 'other',
          summary: key,
          needsAction: needsAction,
          actionItems: const [],
          replyExpected: replyExpected,
          deadline: deadline,
        ),
      );
    }
    if (intent == null && importance == null) return;
    await store.writeExtraction(
      source,
      '$key-m1',
      jsonEncode({
        'intent': intent ?? 'fyi',
        'importance': importance ?? 'normal',
      }),
    );
  }

  Future<String?> bucketOf(String key, {String source = 'email'}) async =>
      (await store.getConversationAi(source, key))?['bucket'] as String?;
  Future<String?> reasonOf(String key, {String source = 'email'}) async =>
      (await store.getConversationAi(source, key))?['bucket_reason'] as String?;
  Future<double?> scoreOf(String key, {String source = 'email'}) async =>
      ((await store.getConversationAi(source, key))?['attention_score'] as num?)
          ?.toDouble();

  group('scoring', () {
    test('scores every open thread and says how many', () async {
      await seed('c1', state: 'needs_reply');
      await seed('c2');

      expect(await service.recomputeAll(now: now), 2);
      expect(await scoreOf('c1'), isNotNull);
      expect(await scoreOf('c2'), isNotNull);
    });

    test('skips threads the user has closed', () async {
      await seed('c1', state: 'done');

      expect(await service.recomputeAll(now: now), 0);
      expect(await scoreOf('c1'), isNull);
    });

    test('a needs-reply thread outranks a waiting one', () async {
      await seed('c1', state: 'needs_reply');
      await seed('c2', state: 'waiting');
      await service.recomputeAll(now: now);

      expect((await scoreOf('c1'))!, greaterThan((await scoreOf('c2'))!));
    });

    test('a later sender scores zero', () async {
      await seed('c1', state: 'needs_reply');
      await store.setSenderPref('eric@x.com', 'later');

      await service.recomputeAll(now: now);
      expect(await scoreOf('c1'), 0);
    });

    test('the intent from the extraction reaches the score', () async {
      await seed('c1', state: 'needs_reply', intent: 'question');
      await seed('c2', state: 'needs_reply', intent: 'fyi');
      await service.recomputeAll(now: now);

      expect((await scoreOf('c1'))!, greaterThan((await scoreOf('c2'))!));
    });

    test('an older thread scores below an identical newer one', () async {
      await seed('c1', state: 'needs_reply', receivedAt: justNow);
      await seed('c2', state: 'needs_reply', receivedAt: '2026-08-01T11:00:00Z');
      await service.recomputeAll(now: now);

      expect((await scoreOf('c1'))!, greaterThan((await scoreOf('c2'))!));
    });

    test('a corrupt extraction blob does not stop the pass', () async {
      await seed('c1', state: 'needs_reply');
      await store.writeExtraction('email', 'c1-m1', 'not json at all');

      expect(await service.recomputeAll(now: now), 1);
      expect(await scoreOf('c1'), isNotNull);
    });

    test('a thread with no messages at all still scores', () async {
      await store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'needs_reply',
        'last_message_at': justNow,
      });

      expect(await service.recomputeAll(now: now), 1);
      expect(await scoreOf('c1'), isNotNull);
    });

    test('an empty mailbox is a no-op', () async {
      expect(await service.recomputeAll(now: now), 0);
    });

    test('the pass is idempotent', () async {
      await seed('c1', state: 'needs_reply', intent: 'question');
      await service.recomputeAll(now: now);
      final first = await scoreOf('c1');
      await service.recomputeAll(now: now);

      expect(await scoreOf('c1'), first);
    });
  });

  group('triage v2 judgments reach the score', () {
    test('a group-chat FYI nobody is waiting on drops out of Needs You',
        () async {
      // The thread this whole temper exists for: a Teams group chat where
      // somebody said something to the room, not to the user. The state machine
      // still calls it needs-reply — an inbound message went unanswered — but
      // triage read it and found no one waiting.
      await seed(
        'tc-todd',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:todd',
        addressedMe: false,
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );

      await service.recomputeAll(sources: both, now: now);

      expect(
        (await scoreOf('tc-todd', source: 'teams'))!,
        closeTo(AttentionTuning.waitingBase * decay, 1e-9),
      );
      expect(
        (await scoreOf('tc-todd', source: 'teams'))!,
        lessThan(AttentionTuning.defaultThreshold),
      );
      // And it is still in the inbox — the temper quiets the rail, it does not
      // file anything into Later.
      expect(await bucketOf('tc-todd', source: 'teams'), isNull);
    });

    test('while an @mention asking a question steps forward', () async {
      await seed(
        'tc-mention',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:todd',
        addressedMe: true,
        replyExpected: true,
        intent: 'question',
        importance: 'normal',
      );
      await seed(
        'tc-todd',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:todd',
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );

      await service.recomputeAll(sources: both, now: now);

      // Base 1.0, the question bonus, then the direct boost.
      expect(
        (await scoreOf('tc-mention', source: 'teams'))!,
        closeTo(
          (1.0 + AttentionTuning.questionBonus) *
              decay *
              AttentionTuning.directBoost,
          1e-9,
        ),
      );
      expect(
        (await scoreOf('tc-mention', source: 'teams'))!,
        greaterThan((await scoreOf('tc-todd', source: 'teams'))!),
      );
    });

    test('a sole-recipient email is boosted the same way', () async {
      await seed('c-sole',
          state: 'needs_reply', addressedMe: true, replyExpected: true);

      await service.recomputeAll(now: now);

      expect(
        (await scoreOf('c-sole'))!,
        closeTo(decay * AttentionTuning.directBoost, 1e-9),
      );
    });

    test('a named deadline reaches the scorer and blocks the temper', () async {
      // Pins the `deadline` column riding through latestInboundMeta: without
      // it this thread would temper to 0.35 on its fyi intent alone.
      await seed(
        'c-deadline',
        state: 'needs_reply',
        replyExpected: false,
        deadline: 'by Friday',
        intent: 'fyi',
        importance: 'low',
      );

      await service.recomputeAll(now: now);

      expect((await scoreOf('c-deadline'))!, closeTo(decay, 1e-9));
    });

    test('and so does a needed action', () async {
      await seed(
        'c-action',
        state: 'needs_reply',
        replyExpected: false,
        needsAction: true,
        intent: 'fyi',
        importance: 'low',
      );

      await service.recomputeAll(now: now);

      expect((await scoreOf('c-action'))!, closeTo(decay, 1e-9));
    });

    test('a thread triage v2 never judged scores exactly as it did before',
        () async {
      // The columns read NULL for every thread that predates v2, and NULL is
      // never treated as "no reply expected". This is the untempered chain,
      // unchanged: base 1.0 plus the question bonus, decayed.
      await seed('c-legacy', state: 'needs_reply', intent: 'question');

      await service.recomputeAll(now: now);

      expect(
        (await scoreOf('c-legacy'))!,
        closeTo((1.0 + AttentionTuning.questionBonus) * decay, 1e-9),
      );
    });

    test('Teams reply rates reach the score too', () async {
      // Proves the second senderReplyRates call is wired: only the rate bonus
      // can push a plain needs-reply thread above 1.0, and only a Teams-source
      // query can find the rate for a `teams:` address.
      await seed('tc-answered',
          source: 'teams',
          state: 'needs_reply',
          from: 'teams:nina',
          answered: true);
      await seed('tc-quiet',
          source: 'teams', state: 'needs_reply', from: 'teams:pat');

      await service.recomputeAll(sources: both, now: now);

      expect(
        (await scoreOf('tc-answered', source: 'teams'))!,
        closeTo((1.0 + AttentionTuning.replyRateMax) * decay, 1e-9),
      );
      expect((await scoreOf('tc-answered', source: 'teams'))!, greaterThan(1.0));
      expect((await scoreOf('tc-quiet', source: 'teams'))!, lessThan(1.0));
    });

    test('but a tempered thread gets no rate nudge', () async {
      // The regression the temper is written around, through the store this
      // time: 0.35 + 0.2 would land at 0.55 and put this thread straight back
      // into Needs You.
      await seed(
        'tc-answered-fyi',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:nina',
        answered: true,
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );

      await service.recomputeAll(sources: both, now: now);

      expect(
        (await scoreOf('tc-answered-fyi', source: 'teams'))!,
        closeTo(AttentionTuning.waitingBase * decay, 1e-9),
      );
      expect(
        (await scoreOf('tc-answered-fyi', source: 'teams'))!,
        lessThan(AttentionTuning.defaultThreshold),
      );
    });
  });

  group('the needs-you verdict reaches the score', () {
    test('a 1:1 chat FYI the stage judged yes climbs back into Needs You',
        () async {
      // The complaint end to end. Both threads are the same shape — a chat
      // message triage read as a quiet FYI on a thread nobody answered — and
      // the only difference is that the needs-you stage read one of them whole
      // and found a real ask in it. The tempered one stays out of Needs You;
      // the judged one clears the default cut with no slider moved.
      await seed(
        'tc-judged',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:priya',
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );
      await store.writeNeedsYouVerdict(
        'teams',
        'tc-judged-m1',
        verdict: true,
        reason: 'asks you to confirm the room before Thursday',
      );
      await seed(
        'tc-unjudged',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:priya',
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );

      await service.recomputeAll(sources: both, now: now);

      expect(
        (await scoreOf('tc-judged', source: 'teams'))!,
        closeTo(AttentionTuning.needsReplyBase * decay, 1e-9),
      );
      expect(
        (await scoreOf('tc-judged', source: 'teams'))!,
        greaterThan(AttentionTuning.defaultThreshold),
      );
      expect(
        (await scoreOf('tc-unjudged', source: 'teams'))!,
        closeTo(AttentionTuning.waitingBase * decay, 1e-9),
      );
      expect(
        (await scoreOf('tc-unjudged', source: 'teams'))!,
        lessThan(AttentionTuning.defaultThreshold),
      );
    });

    test('the meta row carries the NEWEST message\'s verdict, not the thread\'s',
        () async {
      // The verdict is per-message, and the scorer asks about one message: the
      // newest inbound one. An older message judged yes says nothing about the
      // heads-up that landed after it.
      await store.upsertConversation({
        'conversation_key': 'c-two',
        'state': 'needs_reply',
        'last_message_at': justNow,
        'last_inbound_at': justNow,
      });
      await store.upsertMessage({
        'source_message_id': 'c-two-old',
        'conversation_key': 'c-two',
        'direction': 'inbound',
        'from_address': 'alex@example.com',
        'received_at': '2026-08-28T10:00:00Z',
      });
      await store.upsertMessage({
        'source_message_id': 'c-two-new',
        'conversation_key': 'c-two',
        'direction': 'inbound',
        'from_address': 'alex@example.com',
        'received_at': justNow,
      });
      await store.writeNeedsYouVerdict('email', 'c-two-old', verdict: true);

      final meta = await store.latestInboundMeta();

      expect(meta['c-two']!['source_message_id'], 'c-two-new');
      expect(meta['c-two']!['needs_you_verdict'], isNull);

      // And the column really does ride along once it is on that message.
      await store.writeNeedsYouVerdict('email', 'c-two-new',
          verdict: false, reason: 'nothing here to answer');

      expect((await store.latestInboundMeta())['c-two']!['needs_you_verdict'], 0);
    });
  });

  group('bucket sweep', () {
    test('files a low-value fyi into Later', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'low_value');
    });

    test('and clears it again once the message stops being low-value', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);
      expect(await bucketOf('c1'), 'later');

      await store.writeExtraction(
        'email',
        'c1-m1',
        jsonEncode({'intent': 'request', 'importance': 'high'}),
      );
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
      expect(await reasonOf('c1'), isNull);
    });

    test('never defers a thread awaiting the user', () async {
      await seed('c1', state: 'needs_reply', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('leaves a thread with no extraction in the inbox', () async {
      await seed('c1');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('a later sender rule defers even a high-importance request', () async {
      await seed('c1', intent: 'request', importance: 'high');
      await store.setSenderPref('eric@x.com', 'later');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'sender_pref');
    });

    test('a keep rule beats the model and clears a low_value bucket', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await service.recomputeAll(now: now);
      expect(await bucketOf('c1'), 'later');

      await store.setSenderPref('eric@x.com', 'keep');
      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('the sweep never clears a bucket a sender rule put there', () async {
      await seed('c1', intent: 'request', importance: 'high');
      await store.setSenderPref('eric@x.com', 'later');
      store.rebucketSender('eric@x.com', bucket: 'later');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'sender_pref');
    });

    test('and never touches a thread a person deferred by hand', () async {
      // `user` is the most specific instruction anyone gave about this thread.
      // Nothing automatic gets to undo it in either direction.
      await seed('c1', intent: 'request', importance: 'high');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'user');
    });

    test('a keep rule does not undo a hand-deferred thread either', () async {
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');
      await store.setSenderPref('eric@x.com', 'keep');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'user');
    });

    test('the LATEST inbound sender decides which rule applies', () async {
      // Two senders on one thread; the newer one owns it.
      await store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'waiting',
        'last_message_at': justNow,
        'last_inbound_at': justNow,
      });
      await store.upsertMessage({
        'source_message_id': 'm-old',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'news@bulk.com',
        'received_at': '2026-08-01T10:00:00Z',
      });
      await store.upsertMessage({
        'source_message_id': 'm-new',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'dana@y.com',
        'received_at': justNow,
      });
      await store.setSenderPref('news@bulk.com', 'later');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull,
          reason: "the newsletter no longer owns a thread Dana replied on");
    });

    test('a done thread is swept but not scored', () async {
      await seed('c1', state: 'done', intent: 'fyi', importance: 'low');

      expect(await service.recomputeAll(now: now), 0);
      expect(await bucketOf('c1'), 'later');
      expect(await scoreOf('c1'), isNull);
    });
  });
}
