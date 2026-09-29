import 'package:bond_inbox/data/database.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/services/conversation_cta.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// `foldCtaUp`, the one fold both callers share: the triage queue (the
/// decision's urgency and category) and the message-text handler (the ask,
/// when the text lands). The wording rules moved here from
/// `triage_queue_test.dart` with the function.
void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() async => db.close());

  Future<void> seedConversation({
    String? lastInboundAt = '2026-08-29T10:00:00Z',
    String? lastOutboundAt,
    String state = 'needs_reply',
  }) =>
      store.upsertConversation({
        'source': 'email',
        'conversation_key': 'conv-1',
        'subject': 'Launch date',
        'state': state,
        'last_inbound_at': lastInboundAt,
        'last_outbound_at': lastOutboundAt,
        'last_message_at': lastOutboundAt ?? lastInboundAt,
      });

  Map<String, Object?> row({String receivedAt = '2026-08-29T10:00:00Z'}) => {
        'conversation_key': 'conv-1',
        'received_at': receivedAt,
      };

  Future<Map<String, Object?>> conversation() async =>
      (await store.getConversationRow('email', 'conv-1'))!;

  final now = DateTime(2026, 8, 29, 12);

  Future<void> fold({
    String urgency = 'high',
    String? category = 'work',
    bool needsAction = true,
    String summary = 'Jordan asks about the launch date.',
    List<String> actionItems = const ['Call Sarah about the lock'],
    String deadline = '',
    String receivedAt = '2026-08-29T10:00:00Z',
  }) =>
      foldCtaUp(
        store,
        'email',
        row(receivedAt: receivedAt),
        urgency: urgency,
        category: category,
        needsAction: needsAction,
        summary: summary,
        actionItems: actionItems,
        deadline: deadline,
        now: now,
      );

  test('the first action item becomes the thread CTA', () async {
    await seedConversation();
    await fold(urgency: 'urgent', actionItems: const ['Send the final invoice']);

    final c = await conversation();
    expect(c['cta_text'], 'Send the final invoice');
    expect(c['cta_urgency'], 'urgent');
    expect(c['category'], 'work');
  });

  test('with no action items, a needed summary stands in', () async {
    await seedConversation();
    await fold(
      summary: 'Sarah is waiting on the lock extension.',
      actionItems: const [],
    );

    expect(
      (await conversation())['cta_text'],
      'Sarah is waiting on the lock extension.',
    );
  });

  test('a deadline rides along on the CTA', () async {
    await seedConversation();
    await fold(
      actionItems: const ['Send the final invoice'],
      deadline: 'Friday',
    );

    expect(
      (await conversation())['cta_text'],
      'Send the final invoice — by Friday',
    );
  });

  test('a CTA with its deadline still fits the cap', () async {
    await seedConversation();
    // An ask already at the cap: appending the deadline must cost the ask its
    // tail rather than push the pair over.
    await fold(actionItems: ['a' * 200], deadline: 'Friday');

    final cta = (await conversation())['cta_text'] as String;
    expect(cta.length, conversationCtaCap);
    expect(cta, startsWith('aaa'));
  });

  test('no deadline leaves the ask exactly as the model wrote it', () async {
    await seedConversation();
    await fold(actionItems: const ['Send the invoice']);

    expect((await conversation())['cta_text'], 'Send the invoice');
  });

  test('a plan-relative deadline is not stamped into the banner', () async {
    await seedConversation();
    await fold(actionItems: const ['Send the invoice'], deadline: 'Day 1');

    expect((await conversation())['cta_text'], 'Send the invoice');
  });

  test('a deadline with nothing to hang it on adds no CTA', () async {
    await seedConversation();
    await fold(needsAction: false, actionItems: const [], deadline: 'Friday');

    // " — by Friday" on its own is not an ask.
    expect((await conversation())['cta_text'], isNull);
  });

  test('a message that needs nothing leaves no CTA, but its urgency lands',
      () async {
    await seedConversation();
    await fold(urgency: 'low', needsAction: false, actionItems: const []);

    final c = await conversation();
    expect(c['cta_text'], isNull);
    expect(c['cta_urgency'], 'low');
  });

  test('before the text lands the ask is kept and the urgency moves',
      () async {
    await seedConversation();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'An older ask',
      ctaUrgency: 'low',
    );
    await foldCtaUp(
      store,
      'email',
      row(),
      urgency: 'high',
      category: 'notification',
      needsAction: true,
      textLanded: false,
      now: now,
    );

    final c = await conversation();
    expect(c['cta_text'], 'An older ask');
    expect(c['cta_urgency'], 'high');
    expect(c['category'], 'notification');
  });

  test('text that asks for nothing clears the ask when it lands', () async {
    await seedConversation();
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'An older ask',
      ctaUrgency: 'low',
    );
    await fold(
      summary: 'A receipt.',
      actionItems: const [],
      needsAction: false,
      urgency: 'low',
    );

    expect((await conversation())['cta_text'], isNull);
  });

  test('the guards hold before the text lands too', () async {
    await seedConversation(
      lastInboundAt: '2026-08-29T10:00:00Z',
      lastOutboundAt: '2026-08-29T11:00:00Z',
      state: 'waiting',
    );
    await foldCtaUp(
      store,
      'email',
      row(),
      urgency: 'urgent',
      needsAction: true,
      textLanded: false,
      now: now,
    );

    expect((await conversation())['cta_urgency'], isNot('urgent'));
  });

  test("an older message never overwrites the newest inbound message's ask",
      () async {
    await seedConversation(lastInboundAt: '2026-08-29T10:00:00Z');
    await store.updateConversationTriage(
      'email',
      'conv-1',
      ctaText: 'Send the project brief',
      ctaUrgency: 'urgent',
      category: 'work',
    );
    await fold(
      urgency: 'low',
      actionItems: const ['Reply about parking'],
      receivedAt: '2026-08-20T09:00:00Z',
    );

    final c = await conversation();
    expect(c['cta_text'], 'Send the project brief');
    expect(c['cta_urgency'], 'urgent');
  });

  test('an ask the user already answered never comes back as a CTA',
      () async {
    await seedConversation(
      lastInboundAt: '2026-08-29T10:00:00Z',
      lastOutboundAt: '2026-08-29T11:00:00Z',
      state: 'waiting',
    );
    await fold(
      urgency: 'urgent',
      actionItems: const ['Confirm attendance'],
      deadline: 'Friday',
    );

    final c = await conversation();
    expect(c['cta_text'], isNull);
    expect(c['cta_urgency'], 'normal');
    expect(c['state'], 'waiting');
  });

  test('a reply at the same instant as the ask still counts as the answer',
      () async {
    // Ties resolve toward the reply, as `outboundResolves` reads them.
    await seedConversation(
      lastInboundAt: '2026-08-29T10:00:00Z',
      lastOutboundAt: '2026-08-29T10:00:00Z',
      state: 'waiting',
    );
    await fold(actionItems: const ['Confirm attendance']);

    expect((await conversation())['cta_text'], isNull);
  });

  test('an ask newer than the last reply still folds up', () async {
    await seedConversation(
      lastInboundAt: '2026-08-29T12:00:00Z',
      lastOutboundAt: '2026-08-29T11:00:00Z',
    );
    await fold(
      actionItems: const ['Send the revised draft'],
      receivedAt: '2026-08-29T12:00:00Z',
    );

    expect((await conversation())['cta_text'], 'Send the revised draft');
  });

  test('a message with no conversation folds up into nothing', () async {
    await foldCtaUp(
      store,
      'email',
      const {'conversation_key': 'orphan', 'received_at': 'x'},
      urgency: 'high',
      needsAction: true,
      actionItems: const ['Anything'],
    );

    expect(await store.getConversationRow('email', 'orphan'), isNull);
  });
}
