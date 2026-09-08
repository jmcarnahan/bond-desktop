import 'dart:typed_data';

// `show`: drift generates row classes named Message/Conversation from the
// tables, and this file means the app's own models.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/widgets/attachment_card.dart';
import 'package:bond_inbox/widgets/files_pane.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/attachment_viewer_pane.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_attachment_bytes.dart';
import 'fixtures/fake_pdf_renderer.dart';
import 'fixtures/png_fixture.dart';
import 'fixtures/test_db.dart';

/// The Files stop, as the SHELL assembles it.
///
/// `files_pane_test.dart` pins what the pane does with a list it is handed;
/// this file pins where that list comes from and what the two ways out of a row
/// actually open — a file BESIDE with its thread carried along, and the thread
/// itself beside.

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
    String subject = 'Homepage copy',
    String name = 'Quote.pdf',
    String attachmentId = 'a1',
    String kind = 'file',
    String? contentType = 'application/pdf',
    String receivedAt = '2026-08-28T09:00:00Z',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.com',
      'received_at': receivedAt,
      'body_text': 'The quote is attached.',
      'has_attachments': 1,
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.com"}]',
      'state': 'waiting',
      'last_message_at': receivedAt,
    });
    await store.upsertAttachments('email', '$key-m1', [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': kind,
        'name': name,
        'content_type': contentType,
        'size': 240 * 1024,
      },
    ]);
    bytes.bytesByKey['email|$key-m1|$attachmentId'] =
        Uint8List.fromList(onePixelPng);
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
      initialSectionProvider.overrideWithValue(RailSection.home),
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

  Future<void> openFiles(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.byTooltip('Files'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the stop opens the shelf, and the shelf is the whole mailbox',
      (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);

    expect(find.byType(FilesPane), findsOneWidget);
    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(find.text('Quote.pdf'), findsWidgets);
    await settleQueues(tester);
  });

  testWidgets('the column beside it is the four shelves', (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);

    expect(
      find.descendant(
        of: find.byType(AppRail),
        matching: find.byKey(const ValueKey('files-kind-images')),
      ),
      findsOneWidget,
    );
    await settleQueues(tester);
  });

  testWidgets('picking a shelf on the rail re-reads the pane under it',
      (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);

    expect(find.byType(AttachmentCard), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('files-kind-images')));
    await tester.pump();
    await tester.pump();

    // The pdf is not a picture, so the Images shelf is empty — and the pane
    // says so rather than showing a stale card.
    expect(find.byType(AttachmentCard), findsNothing);
    expect(find.byKey(FilesPane.emptyKey), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a card opens the file beside, with the shelf still in the main '
      'pane', (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);

    await tester.tap(find.byType(AttachmentCard));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(SidePanelHost), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(AttachmentPreviewPanel),
      ),
      findsOneWidget,
    );
    // The list does not go away underneath the reader.
    expect(find.byType(FilesPane), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Expand on a shelf file fills the pane, and Back returns to the '
      'shelf with the file still beside it', (tester) async {
    // The full viewer used to stand only over a thread or a storyline; a file
    // off the shelf, a room or a person's files reached its ⤢ and vanished.
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);
    await tester.tap(find.byType(AttachmentCard));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsOneWidget);
    expect(find.byType(FilesPane), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(FilesPane), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(AttachmentPreviewPanel),
      ),
      findsOneWidget,
    );
    await settleQueues(tester);
  });

  testWidgets('the caption opens the thread the file came with, beside',
      (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);

    await tester.tap(find.text('Homepage copy'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(ThreadDetailPanel),
      ),
      findsOneWidget,
    );
    expect(find.byType(FilesPane), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Home takes the reader back off it — Files is a stop of its own',
      (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openFiles(tester);
    expect(find.byType(FilesPane), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.byTooltip('Home'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // Not a row in the Home stack, so leaving it leaves it entirely.
    expect(find.byType(FilesPane), findsNothing);
    expect(find.byType(HomePane), findsOneWidget);
    await settleQueues(tester);
  });
}

/// A workbook nothing in this file opens — the screen needs a decoder, and
/// nothing on this shelf is a spreadsheet.
Future<WorkbookTables> _decoder(Uint8List bytes) async =>
    throw UnimplementedError();
