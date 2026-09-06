import 'dart:io';
import 'dart:typed_data';

// `show BondDatabase`: drift generates a row class named Message from the
// table, and this file means the app's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/attachment_chip.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/inline_image_thumb.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/attachment_viewer_pane.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_attachment_bytes.dart';
import 'fixtures/fake_pdf_renderer.dart';
import 'fixtures/png_fixture.dart';
import 'fixtures/test_db.dart';

/// A file opened beside the thread that carried it, as the SCREEN assembles
/// it: the split, the full pane, and the three places a preview has to
/// disappear.
///
/// The screen is handed fakes for all three attachment collaborators, which is
/// the whole reason those props exist — the real pair would load pdfium and
/// reach a platform channel, neither of which a test process has.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A save panel that answers with a path the test picked, and remembers what
/// name it was offered.
class _FakeDialogs implements FileDialogs {
  String? answer;
  String? suggested;

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async {
    suggested = suggestedName;
    return answer;
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ProviderContainer container;
  late FakeAttachmentBytes bytes;
  late _FakeDialogs dialogs;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    bytes = FakeAttachmentBytes();
    dialogs = _FakeDialogs();
  });

  tearDown(() => db.close());

  /// One inbound mail carrying one file.
  Future<void> seedThread({
    String key = 'c1',
    String name = 'Terms.pdf',
    String contentType = 'application/pdf',
    String attachmentId = 'a1',
    int size = 240 * 1024,
    bool needsReply = false,
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': 'Survey window',
      'from_name': 'Dana Whitfield',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The terms are attached.',
      'has_attachments': 1,
    });
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': 'Survey window',
      'state': needsReply ? 'needs_reply' : 'waiting',
      'cta_text': needsReply ? 'Confirm the survey window' : null,
      'last_message_at': '2026-08-28T09:00:00Z',
    });
    await store.upsertAttachments('email', '$key-m1', [
      {
        'attachment_id': attachmentId,
        'ordinal': 0,
        'kind': 'file',
        'name': name,
        'content_type': contentType,
        'size': size,
      },
    ]);
    // The bytes the panel will ask for, keyed the way the seam keys them.
    bytes.bytesByKey['email|$key-m1|$attachmentId'] =
        Uint8List.fromList(onePixelPng);
  }

  Future<void> pumpInbox(
    WidgetTester tester, {
    Size surface = const Size(1400, 900),
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
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
          fileDialogs: dialogs,
        ),
      ),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> openThread(WidgetTester tester, {String key = 'c1'}) async {
    container
        .read(navIntentProvider.notifier)
        .request(OpenThreadIntent('email', key));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Runs out every window the queues arm behind them, so a test does not end
  /// with one pending — the same three the home screen's tests wait on.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Future<void> openAttachment(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(AttachmentChip, label));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('tapping a chip splits the pane', (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);

    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    await openAttachment(tester, 'Terms.pdf');

    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    // Beside the transcript, not instead of it.
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('closing gives the width back', (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');

    await tester.tap(find.byKey(AttachmentPreviewPanel.closeKey));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('under 960 wide the preview replaces the transcript',
      (tester) async {
    await seedThread();
    await pumpInbox(tester, surface: const Size(900, 900));
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');

    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('the composer stays under the split', (tester) async {
    await seedThread(needsReply: true);
    await pumpInbox(tester);
    await openThread(tester);

    // The box opens on the ask, before the preview does anything to the pane.
    await tester.tap(find.text('Confirm the survey window'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Composer), findsOneWidget);

    await openAttachment(tester, 'Terms.pdf');

    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    expect(find.byType(Composer), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Expand fills the main pane and Back returns to the split',
      (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');

    await tester.tap(find.byKey(AttachmentPreviewPanel.expandKey));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsOneWidget);
    expect(find.byType(ThreadDetailPanel), findsNothing);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Home from the full viewer clears everything', (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');
    await tester.tap(find.byKey(AttachmentPreviewPanel.expandKey));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Home'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('selecting another thread takes the preview with it',
      (tester) async {
    await seedThread();
    await seedThread(key: 'c2', attachmentId: 'b1', name: 'Quote.pdf');
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');
    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);

    await openThread(tester, key: 'c2');

    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a picture asked for once is asked for once', (tester) async {
    await seedThread(name: 'Screenshot.png', contentType: 'image/png');
    bytes.thumbnailsByKey['email|c1-m1|a1'] =
        Uint8List.fromList(onePixelPng);

    await pumpInbox(tester);
    await openThread(tester);
    expect(bytes.thumbnailCalls, 1);

    // A second build of the same rows — the poll causes one every minute — must
    // not spend a second fetch, and the picture that arrived must still be
    // the same provider instance.
    final first = tester
        .widget<InlineImageThumb>(find.byType(InlineImageThumb).first)
        .image;
    await tester.pump();
    await tester.pump();
    final second = tester
        .widget<InlineImageThumb>(find.byType(InlineImageThumb).first)
        .image;

    expect(bytes.thumbnailCalls, 1);
    expect(identical(first, second), isTrue);
    await settleQueues(tester);
  });

  testWidgets('Save writes the bytes where the dialog said', (tester) async {
    final target = File(
      '${Directory.systemTemp.createTempSync('bond-save').path}/Terms.pdf',
    );
    addTearDown(() {
      if (target.parent.existsSync()) target.parent.deleteSync(recursive: true);
    });
    dialogs.answer = target.path;

    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');

    await tester.tap(find.byKey(AttachmentPreviewPanel.saveKey));
    // The panel and the bytes settle on the fake clock; the write itself is
    // real IO on the real event loop, which `pump` alone would never let
    // finish.
    await tester.pump();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(dialogs.suggested, 'Terms.pdf');
    expect(target.existsSync(), isTrue);
    expect(target.readAsBytesSync(), onePixelPng);
    await settleQueues(tester);
  });

  testWidgets('a save that cannot be written says so', (tester) async {
    dialogs.answer = '/definitely/not/a/directory/Terms.pdf';

    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');

    await tester.tap(find.byKey(AttachmentPreviewPanel.saveKey));
    await tester.pump();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Could not save:'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('a cancelled save writes nothing and costs no download',
      (tester) async {
    dialogs.answer = null;

    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');
    final before = bytes.bytesCalls;

    await tester.tap(find.byKey(AttachmentPreviewPanel.saveKey));
    await tester.pump();
    await tester.pump();

    expect(bytes.bytesCalls, before);
    await settleQueues(tester);
  });

  group('use in reply', () {
    testWidgets('opens the box and asks for a draft naming the file',
        (tester) async {
      await seedThread(needsReply: true);
      await pumpInbox(tester);
      await openThread(tester);
      await openAttachment(tester, 'Terms.pdf');

      expect(find.byType(Composer), findsNothing);

      await tester.tap(find.byKey(AttachmentPreviewPanel.useInReplyKey));
      await tester.pump();
      await tester.pump();

      // Opening the box is what makes the new draft visible — a regenerate
      // nobody can see is a spinner in an empty pane.
      expect(find.byType(Composer), findsOneWidget);

      final rows = await db
          .customSelect("SELECT * FROM work_items WHERE task_kind = 'draft'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['payload_json'], contains('a1'));
      await settleQueues(tester);
    });
  });

  group('pin to storyline', () {
    /// The storyline this thread is filed under, and the membership that puts
    /// it there. Seeded the way `inbox_storylines_test.dart` seeds one.
    Future<void> seedStoryline({String key = 'c1'}) async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Survey window',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
    }

    testWidgets('a thread in no storyline is offered no pin', (tester) async {
      await seedThread();
      await pumpInbox(tester);
      await openThread(tester);
      await openAttachment(tester, 'Terms.pdf');

      // Nowhere to pin is no button at all, not a disabled one: there is
      // nothing here the user could do to make it work.
      expect(find.byKey(AttachmentPreviewPanel.pinKey), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('a thread in one pins to it and says which', (tester) async {
      await seedThread();
      await seedStoryline();
      await pumpInbox(tester);
      await openThread(tester);
      await openAttachment(tester, 'Terms.pdf');

      expect(find.byKey(AttachmentPreviewPanel.pinKey), findsOneWidget);
      expect(find.text('Pin to storyline'), findsOneWidget);

      await tester.tap(find.byKey(AttachmentPreviewPanel.pinKey));
      await tester.pump();
      await tester.pump();

      final rows = await db
          .customSelect('SELECT pinned_storyline_id FROM attachments')
          .get();
      expect(rows.single.data['pinned_storyline_id'], 'sl-1');

      // The ref the panel holds is a snapshot, so the label following the
      // write is the whole point of the session-scoped key set.
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Pinned Terms.pdf to Survey window.'), findsOneWidget);
      await settleQueues(tester);
    });
  });
}

/// A workbook nothing in this file opens — the screen needs a decoder, and
/// none of these threads carry a spreadsheet.
Future<WorkbookTables> _decoder(Uint8List bytes) async =>
    throw UnimplementedError();
