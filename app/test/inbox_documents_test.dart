import 'dart:typed_data';

// `show BondDatabase`: drift generates a row class named Storyline from the
// table, and this file means the app's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/attachment_documents_strip.dart';
import 'package:bond_inbox/widgets/preview/attachment_viewer_pane.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_attachment_bytes.dart';
import 'fixtures/fake_pdf_renderer.dart';
import 'fixtures/png_fixture.dart';
import 'fixtures/test_db.dart';

/// The documents shelf on an open storyline, as the SCREEN assembles it.
///
/// `storyline_timeline_test.dart` pins what the panel does with a document
/// list it is handed. This file pins where that list comes from and what
/// happens on the way out of it: the pin column is the only one a person sets
/// by hand, and the shelf is a cached read that every write has to drop.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A Teams connector that answers instantly — the real one asks an MCP stack
/// nothing started, and the launch refresh would never come back.
class _FakeTeamsSync implements TeamsSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<String?> get lastSyncedAt async => null;
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;
  late FakeAttachmentBytes bytes;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    bytes = FakeAttachmentBytes();
  });

  tearDown(() => db.close());

  /// One inbound mail carrying one file, and the conversation row it folds
  /// into.
  Future<void> seedThread({
    String key = 'c1',
    String name = 'Quote.pdf',
    String attachmentId = 'a1',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The quote is attached.',
      'has_attachments': 1,
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Homepage copy',
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
    await store.upsertAttachments('email', '$key-m1', [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': 'file',
        'name': name,
        'content_type': 'application/pdf',
        'size': 240 * 1024,
      },
    ]);
    bytes.bytesByKey['email|$key-m1|$attachmentId'] =
        Uint8List.fromList(onePixelPng);
  }

  /// The storyline the thread is filed under. [pinned] names the attachment
  /// that starts life on its shelf.
  Future<void> seedStoryline({
    String key = 'c1',
    String? pinned,
  }) async {
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
    if (pinned != null) {
      await store.setAttachmentPinned('email', '$key-m1', pinned, 'sl-1');
    }
  }

  /// Runs out every window the queues arm behind them, so a test does not end
  /// with one pending.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(RailSection.needsYou),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: InboxScreen(
          previewEngines: PreviewEngines(
            pdf: FakePdfRenderer(),
            workbook: _decoder,
          ),
          attachmentBytes: bytes,
        ),
      ),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Opens the storyline in the main pane and unfolds its shelf.
  Future<void> openShelf(WidgetTester tester) async {
    await pumpInbox(tester);
    // The rail's storylines section is expanded by default, so the row is
    // already on screen.
    await tester.tap(find.text('Website redesign'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(StorylineTimelinePanel.documentsButtonKey));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the shelf shows what the store says is pinned', (tester) async {
    await seedThread();
    await seedStoryline(pinned: 'a1');

    await openShelf(tester);

    expect(find.text('1 document'), findsOneWidget);
    expect(find.textContaining('Quote.pdf'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a storyline with nothing pinned says so', (tester) async {
    await seedThread();
    await seedStoryline();

    await openShelf(tester);

    expect(find.text('Documents'), findsOneWidget);
    expect(find.byKey(AttachmentDocumentsStrip.emptyKey), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('opening one fills the pane and Back returns to the storyline',
      (tester) async {
    await seedThread();
    await seedStoryline(pinned: 'a1');

    await openShelf(tester);
    await tester.tap(find.textContaining('Quote.pdf'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // There is no split on this pane, so a document opens the whole thing.
    expect(find.byType(AttachmentViewerPane), findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    // Back has nowhere to drop to here, so the preview leaves with the pane
    // and the storyline is what is underneath.
    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('unpinning takes it off the shelf and out of the count',
      (tester) async {
    await seedThread();
    await seedStoryline(pinned: 'a1');

    await openShelf(tester);
    expect(find.text('1 document'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.tap(find.text('Remove document'));
    await tester.pump();
    await tester.pump();

    final rows = await db
        .customSelect('SELECT pinned_storyline_id FROM attachments')
        .get();
    expect(rows.single.data['pinned_storyline_id'], isNull);

    // The shelf is a cached read: without the invalidate the count above would
    // still say one however many documents the storyline actually holds.
    expect(find.text('Documents'), findsOneWidget);
    expect(find.byKey(AttachmentDocumentsStrip.emptyKey), findsOneWidget);
    expect(find.text('Removed Quote.pdf from the storyline.'), findsOneWidget);
    await settleQueues(tester);
  });
}

/// A workbook nothing in this file opens — the screen needs a decoder, and
/// none of these storylines carry a spreadsheet.
Future<WorkbookTables> _decoder(Uint8List bytes) async =>
    throw UnimplementedError();
