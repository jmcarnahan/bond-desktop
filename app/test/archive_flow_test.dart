import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/restore_service.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart'
    show RailSection, laterDayLabel;
import 'package:bond_inbox/widgets/archive_pane.dart' show ArchivePane;
import 'package:bond_inbox/widgets/chips.dart' show BondFilterPill;
import 'package:bond_inbox/widgets/conversation_list_pane.dart';
import 'package:bond_inbox/widgets/home_search.dart' show HomeSearchField;
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

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.archive),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        ...overrides,
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

  testWidgets('a search finds gate-dropped mail without entering its pile',
      (tester) async {
    // No embedding server answers in a widget test, which is the case worth
    // pinning rather than one to work around: the semantic half fails, the
    // text half runs anyway, and a message the gate threw out — which never
    // had a vector to be found by — is still the answer.
    await seedDropped('Vendor invoice 4471');
    await pumpScreen(tester);

    expect(find.text('Vendor invoice 4471'), findsNothing,
        reason: 'the Dropped pile has not been opened');

    final box = find.descendant(
      of: find.byType(HomeSearchField),
      matching: find.byType(TextField),
    );
    await tester.enterText(box, 'invoice');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(ArchivePane.searchSwap);

    expect(find.text('Vendor invoice 4471'), findsOneWidget);
    expect(find.widgetWithText(BondFilterPill, 'Dropped'), findsNothing,
        reason: 'the answer spans the piles, so no pill may claim it');

    await tester.tap(find.text('Back to archive'));
    await tester.pump();
    // Past the end of the swap, not up to it: the outgoing body is still in
    // the tree for the frame the animation finishes on.
    await tester.pump(ArchivePane.searchSwap * 2);

    expect(find.widgetWithText(BondFilterPill, 'Dropped'), findsOneWidget);
    expect(find.text('Vendor invoice 4471'), findsNothing);
  });

  testWidgets('restoring a dropped message clears the pile and the drop',
      (tester) async {
    await seedDropped('Weekly roundup');
    // The real service, wired as the app wires it, MINUS the two pumps: what
    // this test is about is the screen's half — the tap reaching the notifier
    // and the service's writes landing in the store — while the drains those
    // pumps start are model work whose per-item heartbeat timers outlive a
    // widget test's tree. `restore_service_test.dart` runs them against real
    // queues, which is where they belong.
    await pumpScreen(tester, overrides: [
      restoreServiceProvider.overrideWith((ref) => RestoreService(
            ref.watch(messageStoreProvider),
            progress: ref.watch(pipelineProgressProvider),
            ensureBody: ref.watch(syncServiceProvider).ensureMessageBody,
          )),
    ]);

    await tester.tap(find.widgetWithText(BondFilterPill, 'Dropped'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Weekly roundup'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Optimistic: the row is gone before any read came back.
    expect(find.text('Weekly roundup'), findsNothing);

    final message = (await store.getMessageRow('email', 'email-dropped-1'))!;
    expect(message['gate_override'], 'user');
    expect(message['triage_status'], isNot('skipped'));

    final progress = (await db.customSelect(
      'SELECT * FROM message_progress '
      "WHERE source = 'email' AND source_message_id = 'email-dropped-1'",
    ).getSingle())
        .data;
    expect(progress['dropped'], 0);
    expect(progress['drop_reason'], null);
  });
}
