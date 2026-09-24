import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The one-shot that takes "— by Day 1" back off the ask banners triage wrote
/// before `showableDeadline` existed. Only the tail triage appends, only when
/// that tail is plan-relative wording naming no date.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedBanner(String key, String? cta) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'New Request under EDA-100',
      'state': 'needs_reply',
      'last_message_at': MessageStore.isoStamp(DateTime.now().toUtc()),
      'cta_text': cta,
    });
  }

  Future<String?> banner(String key) async {
    final rows = await db
        .customSelect(
          'SELECT cta_text FROM conversations WHERE conversation_key = ?',
          variables: [Variable(key)],
        )
        .get();
    return rows.first.data['cta_text'] as String?;
  }

  test('a Day 1 tail comes off and the ask stays', () async {
    await seedBanner('c1', 'Confirm the upstream source with Ravi — by Day 1');

    expect(await store.stripPlanRelativeBanners(), 1);
    expect(await banner('c1'), 'Confirm the upstream source with Ravi');
  });

  test('every plan-relative counter the live filter drops', () async {
    await seedBanner('c1', 'Ship the dashboard — by sprint 2');
    await seedBanner('c2', 'Close the loop — by T+5');

    expect(await store.stripPlanRelativeBanners(), 2);
    expect(await banner('c1'), 'Ship the dashboard');
    expect(await banner('c2'), 'Close the loop');
  });

  test('a deadline a reader can act on is left exactly as it is', () async {
    await seedBanner('c1', 'Send the deck — by Friday');
    await seedBanner('c2', 'Confirm the room — by within the hour');
    await seedBanner('c3', 'Kick off — by Day 1 (2026-10-05)');

    expect(await store.stripPlanRelativeBanners(), 0);
    expect(await banner('c1'), 'Send the deck — by Friday');
    expect(await banner('c2'), 'Confirm the room — by within the hour');
    expect(await banner('c3'), 'Kick off — by Day 1 (2026-10-05)');
  });

  test('only the appended tail is read, never the ask\'s own words',
      () async {
    // The ask itself says "by Day 1"; triage's tail says Friday.
    await seedBanner('c1', 'Plan what lands — by Day 1 — by Friday');
    await seedBanner('c2', 'Agree what ships by Day 1');
    await seedBanner('c3', null);

    expect(await store.stripPlanRelativeBanners(), 0);
    expect(await banner('c1'), 'Plan what lands — by Day 1 — by Friday');
    expect(await banner('c2'), 'Agree what ships by Day 1');
    expect(await banner('c3'), isNull);
  });

  test('a second pass finds nothing', () async {
    await seedBanner('c1', 'Confirm the source — by Day 1');

    expect(await store.stripPlanRelativeBanners(), 1);
    expect(await store.stripPlanRelativeBanners(), 0);
  });
}
