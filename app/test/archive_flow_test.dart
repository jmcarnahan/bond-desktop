import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart'
    show RailSection, laterDayLabel;
import 'package:bond_inbox/widgets/chips.dart' show BondFilterPill;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/later_digest.dart';
import 'package:bond_inbox/widgets/time_format.dart' show dayKeyOfIso;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The Archive section as the SCREEN wires it: the day rows, the tab pills and
/// the day filter all live in `InboxScreen` state, so how they interact is
/// invisible from `archive_pane_test.dart`'s prop-driven pumps.
///
/// The contract pinned here: a rail day row narrows the Later tab to that day,
/// and picking any pile afterwards LEAVES the day narrowing — while a day is
/// selected the pane is pinned to Later, so a tab change that kept the day
/// would leave the other two pills dead under the user's finger.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> seedThread(
    String key,
    String subject, {
    String state = 'waiting',
    String? bucket,
    required String lastMessageAt,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'email-$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'is_read': 1,
      'received_at': lastMessageAt,
      'body_text': 'body of $subject',
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'state': state,
      'last_message_at': lastMessageAt,
    });
    await store.recomputeConversationCounts('email', key);
    if (bucket != null) {
      await store.setConversationBucket(
        'email',
        key,
        bucket: bucket,
        reason: 'ai',
      );
    }
  }

  /// A message the gate threw out: no conversation row, because the Dropped
  /// pile is messages rather than threads.
  Future<void> seedDropped(String subject, {String id = 'dropped-1'}) async {
    const receivedAt = '2026-09-01T10:00:00Z';
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'email-$id',
      'conversation_key': 'c-$id',
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Alex Rivera',
      'from_address': 'alex.rivera@example.com',
      'received_at': receivedAt,
      'created_at': receivedAt,
      'updated_at': receivedAt,
    });
    await db.customUpdate(
      "UPDATE message_progress SET dropped = 1, drop_reason = 'newsletter', "
      "outcome = 'dropped', triage_state = 'done', settle_state = 'done' "
      "WHERE source = 'email' AND source_message_id = 'email-$id'",
    );
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.archive),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a day row narrows Later, and picking a pile leaves the day',
      (tester) async {
    // Deferred today, so the rail shows exactly one day row whose label this
    // test can compute rather than guess. Relative dates on purpose — an
    // absolute date would rot into "older" and change the label.
    final todayIso = DateTime.now().toUtc().toIso8601String();
    await seedThread('c-later', 'Vendor renewal', bucket: 'later',
        lastMessageAt: todayIso);
    await seedThread('c-done', 'Homepage copy', state: 'done',
        lastMessageAt: todayIso);
    await pumpScreen(tester);

    final dayKey = dayKeyOfIso(todayIso)!;
    await tester.tap(find.text(laterDayLabel(dayKey, 1)));
    await tester.pump();
    await tester.pump();

    // Narrowed: the digest is on screen and the title names the day.
    expect(find.byType(LaterDigestPanel), findsOneWidget);
    expect(find.textContaining('Archive · '), findsOneWidget);

    await tester.tap(find.widgetWithText(BondFilterPill, 'Done'));
    await tester.pump();
    await tester.pump();

    // The pill worked: the done list replaced the digest, and the day
    // narrowing went with it — the title is the whole section again.
    expect(find.byType(ConversationListPane), findsOneWidget);
    expect(find.byType(LaterDigestPanel), findsNothing);
    expect(find.textContaining('Archive · '), findsNothing);
    expect(find.text('Homepage copy'), findsOneWidget);
  });

  testWidgets('arriving at Dropped reads the pile', (tester) async {
    // Nothing else pulls this list — no bus, no first-load — so the tab entry
    // is the only reason a dropped message is ever on screen.
    await seedDropped('Weekly roundup');
    await pumpScreen(tester);

    expect(find.text('Weekly roundup'), findsNothing);

    await tester.tap(find.widgetWithText(BondFilterPill, 'Dropped'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Weekly roundup'), findsOneWidget);
    expect(find.text('Newsletter'), findsOneWidget);
  });

  testWidgets('coming back to Archive re-reads the pile the user left up',
      (tester) async {
    // The dropped list has no bus behind it, so a message that fell while the
    // user was elsewhere only appears because arrival re-reads page one — the
    // rail tap is the arrival here, not the pill tap.
    await seedDropped('Weekly roundup');
    await pumpScreen(tester);

    await tester.tap(find.widgetWithText(BondFilterPill, 'Dropped'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Weekly roundup'), findsOneWidget);

    await tester.tap(find.text('CONVERSATIONS'));
    await tester.pump();
    await seedDropped('Quarterly digest', id: 'dropped-2');
    await tester.tap(find.text('ARCHIVE'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Quarterly digest'), findsOneWidget,
        reason: 'the tab survived the trip away and arrival re-read it');
  });
}
