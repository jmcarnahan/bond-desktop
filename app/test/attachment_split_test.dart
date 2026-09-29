import 'dart:io';
import 'dart:typed_data';

// `show BondDatabase`: drift generates a row class named Message from the
// table, and this file means the app's own.
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/conversations_provider.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/navigation_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/widgets/pane_surface.dart';
import 'package:bond_inbox/screens/new_message_screen.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/attachments/xlsx_reader.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/mail_backend.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/backend/teams_backend.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail;
import 'package:bond_inbox/widgets/attachment_card.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/home_pane.dart';
import 'package:bond_inbox/widgets/hover_actions.dart';
import 'package:bond_inbox/widgets/inline_image_thumb.dart';
import 'package:bond_inbox/widgets/preview/attachment_preview_panel.dart';
import 'package:bond_inbox/widgets/preview/html_preview.dart';
import 'package:bond_inbox/widgets/preview/attachment_viewer_pane.dart';
import 'package:bond_inbox/widgets/preview/preview_engines.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/thread_detail_panel.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
  Future<void> ensureBodiesFor(
    String conversationKey,
    List<String> sourceMessageIds,
  ) async {}

  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// The compose collaborators, for the one test that opens New message over a
/// preview. None of them is exercised past construction: the screen reads the
/// capability off the session and the recents off the store, and the fakes
/// answer "no grant, no account" so nothing here reaches a network.
class _FakeAuth implements AuthSession {
  @override
  Future<bool> get isSignedIn async => true;

  @override
  Future<bool> get needsReconsent async => false;

  @override
  Future<bool> hasScope(String bareScope) async => false;

  @override
  Future<AccountInfo?> get storedAccount async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeMail implements MailBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// `myUserId` throws on purpose: `RecipientSearch` swallows it.
class _FakeTeams implements TeamsBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakePeople implements PeopleBackend {
  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async =>
      const [];

  @override
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'}) async =>
      null;
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

  /// Nothing in this test picks a folder; the seam only has to exist.
  @override
  Future<String?> chooseDirectory() async => null;
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
    List<Override> overrides = const [],
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
      ...overrides,
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
    await tester.tap(find.widgetWithText(AttachmentCard, label));
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

    // The host's ✕, not the panel's: the panel renders with `showHeader:
    // false` inside it, so there is exactly one close control on screen.
    expect(find.byKey(AttachmentPreviewPanel.closeKey), findsNothing);
    await tester.tap(find.byKey(SidePanelHost.closeKey));
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

  testWidgets('New message outranks the full viewer, and Back does not revive it',
      (tester) async {
    await seedThread();
    await pumpInbox(tester, overrides: [
      authSessionProvider.overrideWithValue(_FakeAuth()),
      mailBackendProvider.overrideWithValue(_FakeMail()),
      teamsBackendProvider.overrideWithValue(_FakeTeams()),
      peopleBackendProvider.overrideWithValue(_FakePeople()),
    ]);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');
    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AttachmentViewerPane), findsOneWidget);

    // Compose is first in the pane ladder: it wins over a viewer that was
    // filling the whole pane a moment ago.
    await tester.tap(find.byTooltip('New message'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsOneWidget);
    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsNothing);

    // Leaving compose lands on the overview, not back in the viewer: opening
    // a pane calls `_clearOverlays`, which puts the thread away and the side
    // panel with it.
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewMessageScreen), findsNothing);
    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await settleQueues(tester);
  });

  testWidgets('the composer stays under the split', (tester) async {
    await seedThread(needsReply: true);
    await pumpInbox(tester);
    await openThread(tester);

    // The box is under the thread before the preview does anything to the
    // pane, and the ask above it takes the cursor there rather than opening it.
    expect(find.byType(Composer), findsOneWidget);
    await tester.tap(find.text('Confirm the survey window'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Composer), findsOneWidget);

    await openAttachment(tester, 'Terms.pdf');

    expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
    // In the MAIN pane, under the transcript — scoped, because a thread can be
    // open beside another one and `findsOneWidget` alone would not say which
    // of the two boxes this is.
    expect(find.byType(Composer), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(Composer),
      ),
      findsNothing,
    );
    await settleQueues(tester);
  });

  testWidgets('Expand fills the main pane and Back returns to the split',
      (tester) async {
    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');

    await tester.tap(find.byKey(SidePanelHost.expandKey));
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
    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();

    // Scoped: the icon rail's Inbox stop carries the same word.
    await tester.tap(find.descendant(
      of: find.byType(PaneSurface),
      matching: find.text('Inbox'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    await settleQueues(tester);
  });

  testWidgets('a thread that vanishes under the full viewer strands nobody',
      (tester) async {
    // A sync that moved the thread, a mark-done, a wipe: the conversation
    // simply is not there any more. The viewer rung falls through rather than
    // calling setState in build, and the pane underneath is whatever is left.
    await seedThread();
    await pumpInbox(tester);
    await openThread(tester);
    await openAttachment(tester, 'Terms.pdf');
    await tester.tap(find.byKey(SidePanelHost.expandKey));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AttachmentViewerPane), findsOneWidget);

    await db
        .customStatement("DELETE FROM conversations WHERE conversation_key = 'c1'");
    await db.customStatement("DELETE FROM messages WHERE conversation_key = 'c1'");
    container.invalidate(conversationsProvider);
    // The invalidate drops the notifier; the re-read builds a fresh one and
    // the load is what fills it — the same pair the screen's own refresh does.
    await container.read(conversationsProvider.notifier).load(syncFirst: false);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsNothing);
    // Something is on screen: the app never lands on a blank pane.
    expect(find.byType(HomePane), findsOneWidget);

    // And it does not come back when the next thread is opened either — the
    // viewer belongs to a file on a thread that no longer exists.
    await seedThread(key: 'c2', attachmentId: 'b1', name: 'Quote.pdf');
    await container.read(conversationsProvider.notifier).load(syncFirst: false);
    await tester.pump();
    await tester.pump();
    await openThread(tester, key: 'c2');

    expect(find.byType(AttachmentViewerPane), findsNothing);
    expect(find.byType(AttachmentPreviewPanel), findsNothing);
    expect(find.byType(ThreadDetailPanel), findsOneWidget);
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

    // The exception never reaches the bar: a path or a plugin's own words
    // tell the reader nothing they can act on.
    expect(find.text('Could not save Terms.pdf.'), findsOneWidget);
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
    testWidgets('asks for a draft naming the file, in the box already there',
        (tester) async {
      await seedThread(needsReply: true);
      await pumpInbox(tester);
      await openThread(tester);
      await openAttachment(tester, 'Terms.pdf');

      // Docked through the split: there is no box left to open.
      expect(find.byType(Composer), findsOneWidget);

      await tester.tap(find.byKey(AttachmentPreviewPanel.useInReplyKey));
      await tester.pump();
      await tester.pump();

      expect(find.byType(Composer), findsOneWidget);
      // The cursor goes where the draft will land, so the user is already in
      // the box the words appear in.
      expect(
        tester
            .widget<TextField>(find.descendant(
              of: find.byType(Composer),
              matching: find.byType(TextField),
            ))
            .focusNode
            ?.hasFocus,
        isTrue,
      );

      final rows = await db
          .customSelect("SELECT * FROM work_items WHERE task_kind = 'draft'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['payload_json'], contains('a1'));
      await settleQueues(tester);
    });
  });

  group('a file opened from the thread beside', () {
    /// The storyline that holds [key], and a second thread that does not carry
    /// the file — so the thread the file resolves through is a real choice
    /// rather than the only one on screen.
    Future<void> seedStorylineWith(String key) async {
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Boundary survey',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', key, addedBy: 'auto');
    }

    /// Opens the storyline in the main pane and its episode card beside it.
    ///
    /// Scoped to the rail: the home feed underneath names the storyline the
    /// thread is filed in, on the same words.
    Future<void> openBeside(WidgetTester tester) async {
      await tester.tap(find.descendant(
        of: find.byType(AppRail),
        matching: find.text('Boundary survey'),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('✉ Survey window'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the thread beside carries the only composer on screen',
        (tester) async {
      await seedThread(needsReply: true);
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);

      expect(
        find.descendant(
          of: find.byType(SidePanelHost),
          matching: find.byType(ThreadDetailPanel),
        ),
        findsOneWidget,
      );
      // The spine keeps the main pane and has no box of its own: a storyline
      // is several conversations, and the one the reply belongs to is the one
      // that just opened beside it.
      expect(find.byType(StorylineTimelinePanel), findsOneWidget);

      // Exactly one box on screen, and the thread beside has it. The spine has
      // none of its own: a storyline is several conversations, and the one a
      // reply belongs to is the one that just opened beside it.
      expect(find.byType(Composer), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SidePanelHost),
          matching: find.byType(Composer),
        ),
        findsOneWidget,
      );
      await settleQueues(tester);
    });

    /// The panel's ✕ — "close this panel", which is a pop and not a dismissal
    /// whenever something is underneath.
    Future<void> closeSide(WidgetTester tester) async {
      await tester.tap(find.byKey(SidePanelHost.closeKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    /// The thread beside, by the one widget only it puts on screen.
    final sideThread = find.descendant(
      of: find.byType(SidePanelHost),
      matching: find.byType(ThreadDetailPanel),
    );

    testWidgets('the ✕ on a file opened from it gives the thread back',
        (tester) async {
      await seedThread(needsReply: true);
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);
      await openAttachment(tester, 'Terms.pdf');

      // The words that say where the ✕ goes, before it is pressed: a reader
      // who opened a file out of a conversation must be able to see that the
      // conversation is what they are standing on.
      expect(find.text('Back to Survey window'), findsOneWidget);

      await closeSide(tester);

      // Back to the thread, not to nothing. The storyline in the main pane
      // never moved.
      expect(find.byType(AttachmentPreviewPanel), findsNothing);
      expect(sideThread, findsOneWidget);
      expect(find.byType(StorylineTimelinePanel), findsOneWidget);
      // And the thread is the bottom of the stack now, so it offers no way
      // back — its ✕ is a close, and it says so by drawing no row.
      expect(find.byKey(SidePanelHost.backKey), findsNothing);

      await closeSide(tester);

      // The second ✕ is the dismissal the first one used to be.
      expect(find.byType(SidePanelHost), findsNothing);
      expect(find.byType(StorylineTimelinePanel), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('Escape in the panel does what the ✕ does', (tester) async {
      await seedThread(needsReply: true);
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);
      await openAttachment(tester, 'Terms.pdf');

      // The tap that opened the file was itself inside the panel, which is
      // what put the focus where the binding can see the key.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();

      expect(find.byType(AttachmentPreviewPanel), findsNothing);
      expect(sideThread, findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('the full pane comes back through the file to the thread',
        (tester) async {
      await seedThread(needsReply: true);
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);
      await openAttachment(tester, 'Terms.pdf');

      await tester.tap(find.byKey(SidePanelHost.expandKey));
      await tester.pump();
      await tester.pump();
      expect(find.byType(AttachmentViewerPane), findsOneWidget);
      expect(find.byType(StorylineTimelinePanel), findsNothing);

      // Back from the whole pane is one rung, not all of them: it gives the
      // split back, and the file is still the thing being read.
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
      expect(find.byType(StorylineTimelinePanel), findsOneWidget);
      expect(find.text('Back to Survey window'), findsOneWidget);

      await closeSide(tester);
      expect(sideThread, findsOneWidget);

      // Opening the file again opens the SPLIT and not the pane it was last
      // expanded to: the full-pane rung belongs to one visit, and it was let
      // go of when that visit ended.
      await openAttachment(tester, 'Terms.pdf');
      expect(find.byType(AttachmentViewerPane), findsNothing);
      expect(find.byType(AttachmentPreviewPanel), findsOneWidget);

      await closeSide(tester);
      await closeSide(tester);
      expect(find.byType(SidePanelHost), findsNothing);
      expect(find.byType(AttachmentViewerPane), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('the message a reply was aimed at survives the round trip',
        (tester) async {
      await seedThread(needsReply: true);
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);

      // Name the message the next send answers, the way the hover strip does.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('c1-m1'))));
      await tester.pump();
      await tester.tap(find.byKey(HoverActions.replyKeyFor('c1-m1')));
      await tester.pump();
      expect(find.text('Replying to Dana Whitfield'), findsOneWidget);

      await openAttachment(tester, 'Terms.pdf');
      expect(find.byKey(const Key('replying-to')), findsNothing);

      await closeSide(tester);

      // The caption is back with the thread. Reading the file the message
      // mentioned is not a change of mind about which message is being
      // answered — and the send that follows would otherwise quietly answer
      // the newest one instead.
      expect(sideThread, findsOneWidget);
      expect(find.text('Replying to Dana Whitfield'), findsOneWidget);

      // Closing the THREAD is the change of mind, and that one does clear it.
      await closeSide(tester);
      expect(find.byKey(const Key('replying-to')), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('a page opened from it reads as words, and the ✕ still returns',
        (tester) async {
      // A page is the one kind whose bytes are not the words in it, and it is
      // the kind whose card is built by a channel this process does not have —
      // so it is worth pinning that the stack carries it like any other file.
      await seedThread(
        name: 'scorecard.html',
        contentType: 'text/html',
        needsReply: true,
      );
      // Stored as the markup an older build wrote, so the panel's own reader
      // for those rows is what is under test rather than the ingest converter.
      bytes.textByKey['email|c1-m1|a1'] = '<!DOCTYPE html>\n'
          '<html><body><h1>Boundary scorecard</h1>'
          '<table><tr><th>Segment</th><th>Finding</th></tr>'
          '<tr><td>East edge</td><td>Setback short by four feet</td></tr>'
          '</table></body></html>';
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);
      await openAttachment(tester, 'scorecard.html');

      expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
      // No channel here means no rendering, which is the glyph card — the same
      // thing every host without WebKit behind it gets.
      expect(find.byKey(HtmlPreview.glyphKey), findsOneWidget);
      // The words, converted. Nothing on screen is markup: a reader who opened
      // a page must not be handed its source.
      expect(find.textContaining('Setback short by four feet'), findsOneWidget);
      expect(find.textContaining('<table'), findsNothing);
      expect(find.textContaining('<!DOCTYPE'), findsNothing);
      expect(find.textContaining('<h1'), findsNothing);

      expect(find.text('Back to Survey window'), findsOneWidget);
      await closeSide(tester);

      expect(find.byType(AttachmentPreviewPanel), findsNothing);
      expect(sideThread, findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('the transcript comes back where the reader left it',
        (tester) async {
      await seedThread(needsReply: true);
      // Enough thread above the file to scroll through. It stays on the NEWEST
      // message, at the bottom: that is the one row a transcript never folds,
      // and a folded row shows that it carried files rather than the files.
      for (var i = 0; i < 14; i++) {
        await store.upsertMessage({
          'source': 'email',
          'source_message_id': 'c1-n$i',
          'conversation_key': 'c1',
          'direction': i.isEven ? 'inbound' : 'outbound',
          'subject': 'Survey window',
          'from_name': i.isEven ? 'Priya Raman' : 'You',
          'received_at': '2026-08-27T09:${i.toString().padLeft(2, '0')}:00Z',
          'body_text': 'Note $i on the survey window. The crew is booked for '
              'the morning and the plat has to be signed before they arrive, '
              'so the east boundary needs an answer today.',
        });
      }
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);

      final transcript = find.descendant(
        of: sideThread,
        matching: find.byType(Scrollable),
      );
      await tester.dragUntilVisible(
        find.byType(AttachmentCard),
        transcript.first,
        const Offset(0, -120),
      );
      await tester.pump();
      final left =
          tester.firstState<ScrollableState>(transcript).position.pixels;
      // A real offset, or the assertion below would hold at rest.
      expect(left, greaterThan(0));

      await openAttachment(tester, 'Terms.pdf');
      await closeSide(tester);

      expect(sideThread, findsOneWidget);
      expect(
        tester.firstState<ScrollableState>(transcript).position.pixels,
        left,
      );
      await settleQueues(tester);
    });

    testWidgets('a run the reader opened is still open when they come back',
        (tester) async {
      await seedThread(needsReply: true);
      // An older message of its own, on its own day, so the transcript offers
      // it a fold: the newest message never folds, and a run's continuation
      // never folds alone.
      await store.upsertMessage({
        'source': 'email',
        'source_message_id': 'c1-m0',
        'conversation_key': 'c1',
        'direction': 'inbound',
        'subject': 'Survey window',
        'from_name': 'Priya Raman',
        'received_at': '2026-08-26T09:00:00Z',
        'body_text': 'The county sent the revised plat.\n'
            'The setback on the east edge moved four feet.',
      });
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);

      // Folded to its first line, which is where a transcript the thread has
      // moved past starts.
      expect(find.textContaining('setback on the east edge'), findsNothing);

      // Scoped to the row: every fold on screen wears the same chevron.
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('c1-m0')),
        matching: find.byIcon(Icons.expand_more),
      ));
      await tester.pump();
      expect(find.textContaining('setback on the east edge'), findsOneWidget);

      await openAttachment(tester, 'Terms.pdf');
      await closeSide(tester);

      // The row the reader opened is open. `MessageRow` seeds its own fold once
      // and never again, so a panel that was replaced and rebuilt would have
      // refolded it — the screen remembers which ids were opened instead.
      expect(sideThread, findsOneWidget);
      expect(find.textContaining('setback on the east edge'), findsOneWidget);
      await settleQueues(tester);
    });

    testWidgets('a file from it takes the panel, and Use in reply drafts on it',
        (tester) async {
      await seedThread(needsReply: true);
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);

      await openAttachment(tester, 'Terms.pdf');

      // One side panel, and the file has it: reading a file from a thread
      // beside is still one thing at a time on that side of the seam. The
      // thread is UNDERNEATH it now rather than gone — the test above this one
      // pins the ✕ that gives it back — but nothing of it is on screen, which
      // is what the three lines below have always said.
      expect(find.byType(AttachmentPreviewPanel), findsOneWidget);
      expect(find.byType(ThreadDetailPanel), findsNothing);
      expect(find.byType(StorylineTimelinePanel), findsOneWidget);

      await tester.tap(find.byKey(AttachmentPreviewPanel.useInReplyKey));
      await tester.pump();
      await tester.pump();

      // The thread comes back beside the spine with its box, and the file
      // goes: the draft is what was asked for, and a box off screen is nothing
      // happening. The main pane is untouched.
      expect(find.byType(AttachmentPreviewPanel), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SidePanelHost),
          matching: find.byType(Composer),
        ),
        findsOneWidget,
      );
      expect(find.byType(StorylineTimelinePanel), findsOneWidget);

      // The draft is asked for on the thread the file came from — the panel
      // carried its origin, which is the only thing that still named it while
      // the thread itself was off the side.
      final rows = await db
          .customSelect("SELECT * FROM work_items WHERE task_kind = 'draft'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['entity_id'], 'c1-m1');
      expect(rows.single.data['payload_json'], contains('a1'));
      await settleQueues(tester);
    });

    testWidgets('and its pin resolves through that thread, not the pane',
        (tester) async {
      // The storyline on screen is NOT the file's answer here: the thread the
      // file came from is a member of a different one, and that is the one a
      // pin belongs to.
      await seedThread();
      await seedStorylineWith('c1');
      await pumpInbox(tester);
      await openBeside(tester);
      await openAttachment(tester, 'Terms.pdf');

      expect(find.byKey(AttachmentPreviewPanel.pinKey), findsOneWidget);

      await tester.tap(find.byKey(AttachmentPreviewPanel.pinKey));
      await tester.pump();
      await tester.pump();

      final rows = await db
          .customSelect('SELECT pinned_storyline_id FROM attachments')
          .get();
      expect(rows.single.data['pinned_storyline_id'], 'sl-1');
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
