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
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/attachment_documents_strip.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/attachment_viewer_pane.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/room_header.dart';
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
/// happens on the way in and out of it: the shelf is every file on the
/// storyline's threads, the pin column is the only one a person sets by hand,
/// and the shelf is a cached read that every write has to drop.

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
    String receivedAt = '2026-08-28T09:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'from_name': 'Dana Whitfield',
      'received_at': receivedAt,
      'body_text': 'The quote is attached.',
      'has_attachments': 1,
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Homepage copy',
      'state': 'waiting',
      'last_message_at': receivedAt,
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

  /// The storyline the threads are filed under. [keys] names every member
  /// thread; [pinned] names the `<conversation key>/<attachment id>` pair that
  /// starts life pinned to it.
  Future<void> seedStoryline({
    List<String> keys = const ['c1'],
    String? pinned,
  }) async {
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    for (final key in keys) {
      await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
    }
    if (pinned != null) {
      final parts = pinned.split('/');
      await store.setAttachmentPinned(
        'email',
        '${parts.first}-m1',
        parts.last,
        'sl-1',
      );
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
    // The list column shows the stop that is lit, so the icon rail comes
    // first; the row is tapped inside the column, because the overview beside
    // it names the same storylines.
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Storylines'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text('Website redesign'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(RoomHeader.tabKey(StorylineTab.files)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets("the shelf lists every document on the storyline's threads, "
      'pinned first', (tester) async {
    await seedThread(receivedAt: '2026-08-20T09:00:00Z');
    await seedThread(
      key: 'c2',
      name: 'Brief.pdf',
      attachmentId: 'a2',
      receivedAt: '2026-08-28T09:00:00Z',
    );
    // The OLDER file is the pinned one, so pinned-first and newest-first
    // disagree — which is the only way to tell which order is actually shown.
    await seedStoryline(keys: ['c1', 'c2'], pinned: 'c1/a1');

    await openShelf(tester);

    // Nobody pinned Brief.pdf and it is on the shelf all the same: membership
    // is the ordinary way a document gets here.
    expect(find.text('Files (2)'), findsOneWidget);
    expect(find.text('📌 📕 Quote.pdf'), findsOneWidget);
    expect(find.text('📕 Brief.pdf'), findsOneWidget);

    final shown = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(StorylineTimelinePanel.documentsStripKey),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .where((text) => text.endsWith('.pdf'))
        .toList();
    expect(shown, ['📌 📕 Quote.pdf', '📕 Brief.pdf']);
    await settleQueues(tester);
  });

  testWidgets('pinning from the shelf floats it and toasts', (tester) async {
    await seedThread(receivedAt: '2026-08-20T09:00:00Z');
    await seedThread(
      key: 'c2',
      name: 'Brief.pdf',
      attachmentId: 'a2',
      receivedAt: '2026-08-28T09:00:00Z',
    );
    await seedStoryline(keys: ['c1', 'c2']);

    await openShelf(tester);
    // Newest first while nothing is pinned.
    expect(find.text('📕 Brief.pdf'), findsOneWidget);

    await tester.tap(find.byKey(
      const ValueKey<String>('document-pin-c1-m1-a1'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final rows = await db
        .customSelect(
          "SELECT pinned_storyline_id FROM attachments "
          "WHERE attachment_id = 'a1'",
        )
        .get();
    expect(rows.single.data['pinned_storyline_id'], 'sl-1');
    expect(find.text('Pinned Quote.pdf to Website redesign.'), findsOneWidget);

    // The shelf is a cached read: without the invalidate the order below would
    // still be the one the pin was supposed to change.
    final shown = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(StorylineTimelinePanel.documentsStripKey),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .where((text) => text.endsWith('.pdf'))
        .toList();
    expect(shown, ['📌 📕 Quote.pdf', '📕 Brief.pdf']);
    await settleQueues(tester);
  });

  testWidgets('a storyline whose threads carry no files says so',
      (tester) async {
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': 'c1',
      'subject': 'Homepage copy',
      'state': 'waiting',
      'last_message_at': '2026-08-28T09:00:00Z',
    });
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'c1-m1',
      'conversation_key': 'c1',
      'direction': 'inbound',
      'subject': 'Homepage copy',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'No file this time.',
    });
    await seedStoryline();

    await openShelf(tester);

    // The bare label, because there is no count to give. Scoped to the tab
    // itself: the icon rail's own Files stop wears the same word.
    expect(
      find.descendant(
        of: find.byKey(RoomHeader.tabKey(StorylineTab.files)),
        matching: find.text('Files'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(AttachmentDocumentsStrip.emptyKey), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('opening one puts it beside the storyline, and Expand and Back '
      'move between the two', (tester) async {
    await seedThread();
    await seedStoryline(pinned: 'c1/a1');

    await openShelf(tester);
    await tester.tap(find.textContaining('Quote.pdf'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Beside the spine, not over it: the storyline is the room the reader is
    // in, and the document is read against it.
    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);

    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    // There is always somewhere to drop back to now — the side panel is the
    // shell's, so Back returns to the split whatever the pane underneath is.
    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    expect(find.byType(StorylineTimelinePanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('unpinning keeps it on the shelf', (tester) async {
    await seedThread();
    await seedStoryline(pinned: 'c1/a1');

    await openShelf(tester);
    expect(find.text('Files (1)'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.tap(find.text('Remove document'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final rows = await db
        .customSelect('SELECT pinned_storyline_id FROM attachments')
        .get();
    expect(rows.single.data['pinned_storyline_id'], isNull);

    // What leaves is the PIN, not the file: the thread is still a member, so
    // the document is still on the shelf — just no longer floated to the top.
    expect(find.text('Files (1)'), findsOneWidget);
    expect(find.byKey(AttachmentDocumentsStrip.emptyKey), findsNothing);
    expect(find.text('📕 Quote.pdf'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('document-pin-c1-m1-a1')),
      findsOneWidget,
    );
    expect(find.text('Unpinned Quote.pdf.'), findsOneWidget);
    await settleQueues(tester);
  });
}

/// A workbook nothing in this file opens — the screen needs a decoder, and
/// none of these storylines carry a spreadsheet.
Future<WorkbookTables> _decoder(Uint8List bytes) async =>
    throw UnimplementedError();
