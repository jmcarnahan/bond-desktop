import 'dart:convert';
import 'dart:math' as math;

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart' show Conversation;
import 'package:bond_inbox/providers/conversations_provider.dart'
    show sameConversationRows;
import 'package:bond_inbox/services/attention.dart';
import 'package:bond_inbox/services/attention_service.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/counting_interceptor.dart';
import 'fixtures/test_db.dart';
import 'fixtures/triage_seed.dart';

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
      await writeTriaged(
        store,
        source,
        '$key-m1',
        status: 'done',
        urgency: 'normal',
        category: 'other',
        summary: key,
        needsAction: needsAction,
        actionItems: const [],
        replyExpected: replyExpected,
        deadline: deadline,
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
      // And it is still in the inbox — the temper lowers the thread in the
      // order, it does not file anything into Later.
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
    });
  });

  group('the needs-you probability reaches the score', () {
    test('a 1:1 chat FYI that needs you climbs back up the order', () async {
      // Both threads are the same shape — a chat message triage read as a
      // quiet FYI on a thread nobody answered — and the only difference is
      // that the decision model placed one of them over the owner's slider.
      // The tempered one sits at the waiting base; the one that needs the
      // owner scores from the full needs-reply base.
      await seed(
        'tc-judged',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:priya',
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );
      await store.writeNeedsYouP(
        'teams',
        'tc-judged-m1',
        p: 0.9,
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
        (await scoreOf('tc-unjudged', source: 'teams'))!,
        closeTo(AttentionTuning.waitingBase * decay, 1e-9),
      );
    });

    test('a probability below the slider does not break the temper',
        () async {
      await seed(
        'tc-low',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:priya',
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );
      await store.writeNeedsYouP('teams', 'tc-low-m1', p: 0.1);

      await service.recomputeAll(sources: both, now: now);

      expect(
        (await scoreOf('tc-low', source: 'teams'))!,
        closeTo(AttentionTuning.waitingBase * decay, 1e-9),
      );
    });

    test("the owner's slider is the cut the sweep reads", () async {
      await seed(
        'tc-mid',
        source: 'teams',
        state: 'needs_reply',
        from: 'teams:priya',
        replyExpected: false,
        intent: 'fyi',
        importance: 'low',
      );
      await store.writeNeedsYouP('teams', 'tc-mid-m1', p: 0.4);
      await store.setPref(needsYouThresholdKey, '0.5');

      await service.recomputeAll(sources: both, now: now);

      // 0.4 needs the owner at the default 0.35, and not at their 0.50.
      expect(
        (await scoreOf('tc-mid', source: 'teams'))!,
        closeTo(AttentionTuning.waitingBase * decay, 1e-9),
      );
    });

    test('the meta row carries the NEWEST message\'s probability, not the '
        'thread\'s', () async {
      // The probability is per-message, and the scorer asks about one message:
      // the newest inbound one. An older message that needs the owner says
      // nothing about the heads-up that landed after it.
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
      await store.writeNeedsYouP('email', 'c-two-old', p: 0.9);

      final meta = await store.latestInboundMeta();

      expect(meta['c-two']!['source_message_id'], 'c-two-new');
      expect(meta['c-two']!['needs_you_p'], isNull);

      // And the column really does ride along once it is on that message.
      await store.writeNeedsYouP('email', 'c-two-new',
          p: 0.1, reason: 'nothing here to answer');

      expect((await store.latestInboundMeta())['c-two']!['needs_you_p'], 0.1);
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

    test('a drop rule files the thread the same way a later one does',
        () async {
      // The sweep does not know the difference and should not: dropping a
      // sender quiets the threads already here, and gates only what is next.
      await seed('c1', intent: 'request', importance: 'high');
      await store.setSenderPref('eric@x.com', 'drop');
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

    test('an open ask keeps a quiet FYI thread in the inbox', () async {
      // The shape Later used to hide: the model read the newest message as a
      // low-value FYI, but its needs-you probability clears the slider and
      // nobody has answered it.
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.writeNeedsYouP('email', 'c1-m1',
          p: 0.9, reason: 'asks the owner to pick a date');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
      expect(await reasonOf('c1'), isNull);
    });

    test('and lets it defer once the owner has answered', () async {
      // The ask closes on the thread's last outbound message, whatever it was
      // a reply to. After that the thread is quiet again.
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.writeNeedsYouP('email', 'c1-m1',
          p: 0.9, reason: 'asks the owner to pick a date');
      const answeredAt = '2026-08-29T11:30:00Z';
      await store.upsertMessage({
        'source_message_id': 'c1-out',
        'conversation_key': 'c1',
        'direction': 'outbound',
        'from_address': 'me@x.com',
        'received_at': answeredAt,
      });
      // `upsertMessage` does not stamp the thread's outbound watermark — only
      // the folded conversation row carries it, so the seed writes it here.
      await store.upsertConversation({
        'conversation_key': 'c1',
        'state': 'waiting',
        'last_outbound_at': answeredAt,
        'last_message_at': answeredAt,
      });

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'low_value');
    });

    test('an older unanswered ask under a newer quiet FYI still holds',
        () async {
      // The thread-level case, and the reason the filing does not just read
      // the newest message's own probability: the question is two messages
      // back.
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.upsertMessage({
        'source_message_id': 'c1-ask',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'eric@x.com',
        'received_at': '2026-08-28T09:00:00Z',
      });
      await store.writeNeedsYouP('email', 'c1-ask',
          p: 0.9, reason: 'asks the owner to approve the spend');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), isNull);
    });

    test('and a hand-deferred thread is untouched by an open ask', () async {
      // `user` is still the most specific instruction anyone gave. An ask does
      // not overrule someone who deferred this one thread on purpose.
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.writeNeedsYouP('email', 'c1-m1',
          p: 0.9, reason: 'asks the owner to pick a date');
      await store.setConversationBucket('email', 'c1',
          bucket: 'later', reason: 'user');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'user');
    });

    test('a probability on a gated message holds nothing open', () async {
      // The ask the owner threw out by hand keeps its probability on the row,
      // and a thread must not be kept out of Later by a question its owner
      // has already dismissed. Same admission as every other reader of a kept
      // message.
      await seed('c1', intent: 'fyi', importance: 'low');
      await store.upsertMessage({
        'source_message_id': 'c1-ask',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'from_address': 'eric@x.com',
        'received_at': '2026-08-28T09:00:00Z',
        'triage_status': 'skipped',
        'gate_reason': 'user',
      });
      await store.writeNeedsYouP('email', 'c1-ask',
          p: 0.9, reason: 'asks the owner to approve the spend');

      await service.recomputeAll(now: now);

      expect(await bucketOf('c1'), 'later');
      expect(await reasonOf('c1'), 'low_value');
    });

    test('a done thread is swept but not scored', () async {
      await seed('c1', state: 'done', intent: 'fyi', importance: 'low');

      expect(await service.recomputeAll(now: now), 0);
      expect(await bucketOf('c1'), 'later');
      expect(await scoreOf('c1'), isNull);
    });
  });

  group('recompute: one pass, one batch', () {
    Future<String?> stampOf(String key) async =>
        (await store.getConversationAi('email', key))?['updated_at']
            as String?;

    /// A stamp older than any the store writes.
    const oldStamp = '2000-01-01T00:00:00.000000Z';

    Future<void> ageStamp(String key) => db.customUpdate(
          'UPDATE conversation_ai SET updated_at = ? '
          "WHERE source = 'email' AND conversation_key = ?",
          variables: [Variable(oldStamp), Variable(key)],
        );

    test('answers what recomputeAll counted, and what it wrote', () async {
      await seed('c1', state: 'needs_reply', intent: 'question');
      await seed('c2', intent: 'fyi', importance: 'low');
      await seed('c3', state: 'done');

      final pass = await service.recompute(now: now);

      expect(pass.scored, 2);
      expect(pass.scores.keys.toSet(), {
        MessageStore.openAskKey('email', 'c1'),
        MessageStore.openAskKey('email', 'c2'),
      });
      expect(pass.scores[MessageStore.openAskKey('email', 'c1')],
          await scoreOf('c1'));
      expect(
        (await scoreOf('c1'))!,
        closeTo((1.0 + AttentionTuning.questionBonus) * decay, 1e-9),
      );
      expect(pass.buckets, {MessageStore.openAskKey('email', 'c2'): 'later'});
      expect(await bucketOf('c2'), 'later');
    });

    test('an unchanged thread is still written, and stamped (I1)', () async {
      // The notification settle holds a message until
      // `conversation_ai.updated_at` is at or after it, and the pass
      // re-stamping that column is what lets it go. A pass that skipped a
      // write for being unchanged would hold the notification forever.
      await seed('c-open', state: 'needs_reply', intent: 'question');
      // Done, so its only write is the bucket.
      await seed('c-done', state: 'done', intent: 'fyi', importance: 'low');
      await service.recompute(now: now);
      final score = await scoreOf('c-open');
      expect(await bucketOf('c-done'), 'later');

      await ageStamp('c-open');
      await ageStamp('c-done');
      await service.recompute(now: now);

      expect(await scoreOf('c-open'), score, reason: 'bit-identical');
      expect(await bucketOf('c-done'), 'later');
      expect((await stampOf('c-open'))!.compareTo(oldStamp), greaterThan(0));
      expect((await stampOf('c-done'))!.compareTo(oldStamp), greaterThan(0));
    });

    test('the stamp is taken before the pass reads, not after', () async {
      // A message that changes after the pass read it must sort LATER than
      // the pass's stamp, so the settle holds it for the next pass instead of
      // taking a score computed from the older version as a verdict on it.
      await seed('c1', state: 'needs_reply', intent: 'question');
      final reading = _ReadTimingStore(db);
      await AttentionService(reading).recompute(now: now);

      expect(reading.metaReadAt, isNotNull);
      final written = (await stampOf('c1'))!;
      expect(written.compareTo(reading.metaReadAt!), lessThan(0));
    });

    test('the minute clock cuts to the start of the minute', () {
      expect(
        AttentionService.minuteOf(DateTime(2026, 10, 6, 13, 45, 59, 999)),
        DateTime(2026, 10, 6, 13, 45),
      );
      expect(
        AttentionService.minuteOf(DateTime(2026, 10, 6, 13, 45)),
        DateTime(2026, 10, 6, 13, 45),
      );
      final utc =
          AttentionService.minuteOf(DateTime.utc(2026, 10, 6, 13, 45, 30));
      expect(utc, DateTime.utc(2026, 10, 6, 13, 45));
      expect(utc.isUtc, isTrue);
    });

    test('the clock ticks once a minute: two passes in one minute store the '
        'same score', () async {
      await seed('c1', state: 'needs_reply', intent: 'question');
      final before = DateTime.now();
      await service.recompute();
      final first = await scoreOf('c1');
      await service.recompute();
      final second = await scoreOf('c1');
      final after = DateTime.now();

      expect(first, isNotNull);
      // A pass on either side of a minute boundary is allowed to differ —
      // that is the tick — so the equality is only asserted when both passes
      // fell in the same wall-clock minute, which is almost always.
      final sameMinute = before.year == after.year &&
          before.month == after.month &&
          before.day == after.day &&
          before.hour == after.hour &&
          before.minute == after.minute;
      if (sameMinute) expect(second, first);
    });

    test('rows handed over are scored without reading the list again',
        () async {
      await seed('c1', state: 'needs_reply');
      final rows = [
        for (final row in await store.conversationRows())
          Conversation.fromRow(row),
      ];

      final counter = CountingInterceptor();
      final countedDb = countingTestDb(counter);
      addTearDown(countedDb.close);
      final countedStore = MessageStore(countedDb);
      await countedStore.upsertConversation({
        'conversation_key': 'c1',
        'state': 'needs_reply',
        'last_message_at': justNow,
      });
      final counted = AttentionService(countedStore);

      counter.reset();
      await counted.recompute(now: now, conversations: rows);
      expect(
        counter.selects.where((s) => s.contains('FROM conversations c')),
        isEmpty,
      );

      // And without them, the pass reads the list itself — the probe works.
      counter.reset();
      await counted.recompute(now: now);
      expect(
        counter.selects.where((s) => s.contains('FROM conversations c')),
        hasLength(1),
      );
    });
  });

  group('recompute against a counted database', () {
    late CountingInterceptor counter;
    late BondDatabase countedDb;
    late MessageStore countedStore;
    late AttentionService counted;

    setUp(() {
      counter = CountingInterceptor();
      countedDb = countingTestDb(counter);
      countedStore = MessageStore(countedDb);
      counted = AttentionService(countedStore);
    });

    tearDown(() async => countedDb.close());

    Future<void> seedThread(String key, {String state = 'needs_reply'}) async {
      await countedStore.upsertConversation({
        'conversation_key': key,
        'state': state,
        'last_message_at': justNow,
        'last_inbound_at': justNow,
      });
      await countedStore.upsertMessage({
        'source_message_id': '$key-m1',
        'conversation_key': key,
        'direction': 'inbound',
        'from_address': 'ada@example.com',
        'received_at': justNow,
      });
      await countedStore.writeExtraction(
        'email',
        '$key-m1',
        jsonEncode({'intent': 'fyi', 'importance': 'low'}),
      );
    }

    test('every write of the pass is ONE batch, and none is a statement of '
        'its own', () async {
      await seedThread('c1');
      await seedThread('c2', state: 'waiting');
      await seedThread('c3', state: 'done');
      await countedStore.setConversationBucket('email', 'c4',
          bucket: 'later', reason: 'low_value');
      await countedStore.upsertConversation({
        'conversation_key': 'c4',
        'state': 'waiting',
        'last_message_at': justNow,
      });

      counter.reset();
      final pass = await counted.recompute(now: now);

      // Three scores (c1, c2, c4) and three bucket writes (c2 and c3 filed,
      // c4's low_value guess withdrawn) — all of it one round trip.
      expect(pass.scored, 3);
      expect(pass.buckets.length, 3);
      expect(counter.batched, 1);
      expect(counter.inserts, 0);
      expect(counter.updates, 0);
      expect(counter.deletes, 0);
      expect(counter.customs, 0);
    });

    test('a pass over an empty mailbox writes nothing at all', () async {
      counter.reset();
      final pass = await counted.recompute(now: now);

      expect(pass.scored, 0);
      expect(counter.batched, 0);
      expect(counter.singleWrites, 0);
    });
  });

  group('the pass applied to the rows it was handed', () {
    test('equals a fresh read after the pass, and is not vacuous', () async {
      // One thread per thing the pass can do to a row.
      await seed('p-score', state: 'needs_reply', from: 'ada@example.com');
      await seed('p-low',
          from: 'ben@example.com', intent: 'fyi', importance: 'low');
      await seed('p-clear',
          from: 'cy@example.com', intent: 'request', importance: 'high');
      await store.setConversationBucket('email', 'p-clear',
          bucket: 'later', reason: 'low_value');
      await seed('p-later', from: 'later@example.com', intent: 'request');
      await store.setSenderPref('later@example.com', 'later');
      await seed('p-drop', from: 'drop@example.com', intent: 'request');
      await store.setSenderPref('drop@example.com', 'drop');
      await seed('p-keep',
          from: 'keep@example.com', intent: 'fyi', importance: 'low');
      await store.setConversationBucket('email', 'p-keep',
          bucket: 'later', reason: 'low_value');
      await store.setSenderPref('keep@example.com', 'keep');
      await seed('p-done',
          state: 'done',
          from: 'dee@example.com',
          intent: 'fyi',
          importance: 'low');
      await seed('p-user',
          from: 'eve@example.com', intent: 'request', importance: 'high');
      await store.setConversationBucket('email', 'p-user',
          bucket: 'later', reason: 'user');

      final raw = await store.conversationRows();
      final pass = await service.recompute(
        now: now,
        conversations: [for (final row in raw) Conversation.fromRow(row)],
      );
      final patched = pass.applyTo(raw);
      final fresh = await store.conversationRows();

      expect(sameConversationRows(patched, fresh), isTrue);

      Map<String, Object?> rowOf(List<Map<String, Object?>> rows, String key) =>
          rows.singleWhere((r) => r['conversation_key'] == key);
      bool movedRow(String key) =>
          !identical(rowOf(patched, key), rowOf(raw, key));

      // Not vacuous: rows really moved, and each scenario shows in the read.
      expect(movedRow('p-score'), isTrue);
      expect(rowOf(fresh, 'p-score')['attention_score'], isNotNull);
      expect(rowOf(fresh, 'p-low')['bucket'], 'later');
      expect(movedRow('p-clear'), isTrue);
      expect(rowOf(raw, 'p-clear')['bucket'], 'later');
      expect(rowOf(fresh, 'p-clear')['bucket'], isNull);
      expect(rowOf(fresh, 'p-later')['bucket'], 'later');
      expect(rowOf(fresh, 'p-later')['attention_score'], 0.0);
      expect(rowOf(fresh, 'p-drop')['bucket'], 'later');
      expect(rowOf(raw, 'p-keep')['bucket'], 'later');
      expect(rowOf(fresh, 'p-keep')['bucket'], isNull);
      expect(rowOf(fresh, 'p-done')['bucket'], 'later');
      expect(rowOf(fresh, 'p-done')['attention_score'], isNull);
      expect(rowOf(fresh, 'p-user')['bucket'], 'later');
      expect(await reasonOf('p-user'), 'user');
      expect(
        pass.buckets.containsKey(MessageStore.openAskKey('email', 'p-user')),
        isFalse,
      );

      // A second pass at the same instant moves nothing: every row comes
      // back as the very map it was handed, which is what lets the list
      // leave an unchanged screen alone.
      final again = await service.recompute(
        now: now,
        conversations: [for (final row in fresh) Conversation.fromRow(row)],
      );
      final twice = again.applyTo(fresh);
      for (var i = 0; i < fresh.length; i++) {
        expect(identical(twice[i], fresh[i]), isTrue,
            reason: '${fresh[i]['conversation_key']} did not change');
      }
    });

    test('a write lands on its own source when two threads share a key',
        () async {
      // The same key under two sources, and only the open one is scored: a
      // patch keyed on the conversation key alone would put the chat's score
      // on the closed mail thread as well.
      const both = ['email', 'teams'];
      await seed('shared', state: 'done', from: 'ada@example.com');
      await seed('shared',
          source: 'teams', state: 'needs_reply', from: 'teams:ben');

      final raw = await store.conversationRows(sources: both);
      final pass = await service.recompute(
        now: now,
        sources: both,
        conversations: [for (final row in raw) Conversation.fromRow(row)],
      );
      final patched = pass.applyTo(raw);
      final fresh = await store.conversationRows(sources: both);

      expect(sameConversationRows(patched, fresh), isTrue);
      Map<String, Object?> of(List<Map<String, Object?>> rows, String source) =>
          rows.singleWhere((r) => r['source'] == source);
      expect(of(patched, 'teams')['attention_score'], isNotNull);
      expect(of(patched, 'email')['attention_score'], isNull);
      expect(identical(of(patched, 'email'), of(raw, 'email')), isTrue);
    });
  });
}

/// Notes when the pass made its first read, a moment after it asked.
class _ReadTimingStore extends MessageStore {
  _ReadTimingStore(super.db);

  String? metaReadAt;

  @override
  Future<Map<String, Map<String, Object?>>> latestInboundMeta({
    List<String> sources = const ['email'],
  }) async {
    // Long enough that a stamp taken after this read could not tie with it.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    metaReadAt = MessageStore.isoStamp(DateTime.now());
    return super.latestInboundMeta(sources: sources);
  }
}
