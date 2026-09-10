import 'dart:io';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/context_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/home_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/context/directory_access.dart';
import 'package:bond_inbox/services/notification_coordinator.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/services/teams_sync.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show AppRail, RailSection;
import 'package:bond_inbox/models/draft_provenance.dart';
import 'package:bond_inbox/widgets/composer.dart';
import 'package:bond_inbox/widgets/context_file_panel.dart';
import 'package:bond_inbox/widgets/context_panel.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/settings_context_section.dart';
import 'package:bond_inbox/widgets/side_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The link panel as the SCREEN opens it: which gestures reach it, which pane
/// it lands in, and that a switch in it writes a real link row.
///
/// `context_panel_test.dart` pins what the body does with the props it is
/// handed. This pins the wiring — that the header action opens it, that the
/// switch writes through `ContextStore`, that the action's own label counts
/// what it wrote, and that a storyline gets the same panel keyed on itself.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

class _FakeTeamsSync implements TeamsSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<String?> get lastSyncedAt async => null;
}

/// An open panel that answers with a folder the test made.
class _FakeDialogs implements FileDialogs {
  _FakeDialogs(this.folder);

  String? folder;

  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      null;

  @override
  Future<String?> chooseDirectory() async => folder;
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late ContextStore context;
  late Directory folder;
  late _FakeDialogs dialogs;
  late ProviderContainer container;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    context = ContextStore(db);
    folder = Directory.systemTemp.createTempSync('bond-context-panel');
    File('${folder.path}/CLAUDE.md').writeAsStringSync('# ridge\n\nnotes\n');
    dialogs = _FakeDialogs(folder.path);
  });

  tearDown(() async {
    await db.close();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  Future<void> seedThread(
    String key,
    String subject, {
    String cta = 'Send the survey back',
  }) async {
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': '$key-m1',
      'conversation_key': key,
      'direction': 'inbound',
      'subject': subject,
      'from_name': 'Dana Whitfield',
      'from_address': 'dana@example.test',
      'received_at': '2026-08-28T09:00:00Z',
      'body_text': 'The hero paragraph.',
    });
    await store.writeNeedsYouVerdict(
      'email',
      '$key-m1',
      verdict: true,
      reason: 'She asked you to confirm the closing date.',
    );
    await store.upsertConversation({
      'source': 'email',
      'conversation_key': key,
      'subject': subject,
      'participants_json':
          '[{"name":"Dana Whitfield","email":"dana@example.test"}]',
      'state': 'needs_reply',
      'cta_text': cta,
      'last_message_at': '2026-08-28T09:00:00Z',
      'last_inbound_at': '2026-08-28T09:00:00Z',
    });
    await store.recomputeConversationCounts('email', key);
  }

  Future<void> pumpInbox(
    WidgetTester tester, {
    RailSection section = RailSection.needsYou,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await store.setPref(attentionThresholdKey, '0');
    final prefs = await AppPrefsNotifier.read(store);
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      initialSectionProvider.overrideWithValue(section),
      initialAppPrefsProvider.overrideWithValue(prefs),
      syncServiceProvider.overrideWithValue(_FakeSync()),
      teamsSyncProvider.overrideWithValue(_FakeTeamsSync()),
      // No Runner behind a `flutter test` binary: the seam's whole point is
      // that "this build keeps no bookmark" is a legal answer.
      directoryAccessProvider.overrideWithValue(const PlainDirectoryAccess()),
      // A worker with no handlers: Add pumps the queue, and the real reconcile
      // handler would then walk a folder and reach for the embedding server
      // inside a widget test.
      aiWorkerProvider.overrideWithValue(AiWorker(store, handlers: const [])),
      notificationCoordinatorProvider
          .overrideWithValue(NotificationCoordinator(store)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: InboxScreen(fileDialogs: dialogs)),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  /// Opens a thread in the MAIN pane from the rail. A Needs You row is titled
  /// by its ASK, which makes it a `Text.rich` — hence `textContaining`.
  Future<void> openThread(WidgetTester tester, String ask) async {
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.textContaining(ask),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  Future<void> openStoryline(WidgetTester tester, String title) async {
    await tester.tap(find.descendant(
      of: find.byType(IconRail),
      matching: find.text('Storylines'),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.descendant(
      of: find.byType(AppRail),
      matching: find.text(title),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  /// Runs out every window the queues arm behind them, so the test does not
  /// end with one pending: the reload debounce, the home feed's tick window,
  /// and the metrics epoch that follows it.
  Future<void> settleQueues(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(HomeFeedNotifier.tickDebounce);
    await tester.pump(HomeFeedNotifier.metricsDebounce);
  }

  Finder panel() => find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(ContextPanelBody),
      );

  Finder spinner() => find.descendant(
        of: find.byType(SidePanelHost),
        matching: find.byType(CircularProgressIndicator),
      );

  /// Records one activity row through the real recorder, which is what the
  /// sixty-second sync poll and every work item of a drain do. Every provider
  /// behind these two panels watches that stream, so this is the event that
  /// puts them all back into `loading` with a value still in hand.
  Future<void> recordActivity() =>
      container.read(activityLogProvider).record(
            'triage',
            source: 'email',
            entityId: 'c1-m1',
          );

  testWidgets('the thread header opens it, and a switch writes the link',
      (tester) async {
    final id = await context.registerDirectory(
      path: folder.path,
      displayName: 'ridge',
    );
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');

    await tester.tap(find.byKey(const Key('thread-context')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(panel(), findsOneWidget);
    expect(find.text('Context'), findsWidgets);
    expect(find.byKey(ContextPanelBody.toggleKeyFor(id)), findsOneWidget);

    await tester.tap(find.byKey(ContextPanelBody.toggleKeyFor(id)));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    // The link row, written through the real store.
    expect(
      await context.dirIdsLinkedTo(ContextScopeKind.thread, 'email', 'c1'),
      [id],
    );
    // And the header action counts what the room reads. The label is the
    // tooltip on an icon button, which is where a count nobody can see a
    // badge for belongs.
    expect(find.byTooltip('Context · 1'), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Manage takes the reader to the library in Settings',
      (tester) async {
    await context.registerDirectory(path: folder.path, displayName: 'ridge');
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');
    await tester.tap(find.byKey(const Key('thread-context')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    await tester.tap(find.byKey(ContextPanelBody.manageKey));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.text(ContextDirectoriesSection.title), findsOneWidget);
    await settleQueues(tester);
  });

  testWidgets('Add inside a room registers the folder AND links it there',
      (tester) async {
    // Pressing Add inside a room is how a person says "read this here".
    // Registering it and leaving the switch off answers a question nobody
    // asked.
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');
    await tester.tap(find.byKey(const Key('thread-context')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text(ContextPanelBody.emptyLine), findsOneWidget);

    await tester.tap(find.byKey(ContextPanelBody.addKey));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    final dirs = await context.directories();
    expect(dirs, hasLength(1));
    expect(
      await context.dirIdsLinkedTo(ContextScopeKind.thread, 'email', 'c1'),
      [dirs.single.id],
    );
    await settleQueues(tester);
  });

  testWidgets('a storyline opens the same panel, keyed on itself',
      (tester) async {
    final id = await context.registerDirectory(
      path: folder.path,
      displayName: 'ridge',
    );
    await seedThread('c1', 'Homepage copy');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await pumpInbox(tester);
    await openStoryline(tester, 'Website redesign');

    await tester.tap(find.byKey(const Key('storyline-context')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(panel(), findsOneWidget);
    await tester.tap(find.byKey(ContextPanelBody.toggleKeyFor(id)));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    // A storyline id is already global, so the link row carries no connector.
    expect(
      await context.dirIdsLinkedTo(ContextScopeKind.storyline, '', 'sl-1'),
      [id],
    );
    expect(
      await context.dirIdsLinkedTo(ContextScopeKind.thread, 'email', 'c1'),
      isEmpty,
    );
    // And the thread inherits it, which is what a draft on that thread reads.
    expect(
      await context.dirIdsInScope(
        source: 'email',
        conversationKey: 'c1',
        storylineIds: const ['sl-1'],
      ),
      [id],
    );
    await settleQueues(tester);
  });

  testWidgets('a thread lists what its storyline links, without a switch',
      (tester) async {
    final id = await context.registerDirectory(
      path: folder.path,
      displayName: 'ridge',
    );
    await seedThread('c1', 'Homepage copy');
    await store.insertStoryline(
      id: 'sl-1',
      title: 'Website redesign',
      status: 'active',
      createdBy: 'auto',
    );
    await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
    await context.link(id, ContextScopeKind.storyline, '', 'sl-1');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');

    await tester.tap(find.byKey(const Key('thread-context')));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.text('«Website redesign»: ridge'), findsOneWidget);
    // The thread's own switch is still off: it is the storyline's link, and
    // this room has not made one of its own.
    final toggle = tester.widget<Switch>(
      find.byKey(ContextPanelBody.toggleKeyFor(id)),
    );
    expect(toggle.value, isFalse);
    await settleQueues(tester);
  });

  testWidgets('an activity row does not blink the switches away',
      (tester) async {
    // Every provider behind this panel watches the activity stream, so a
    // sixty-second poll or one work item of a drain puts them back into
    // `loading`. Answering that with a spinner would replace a switch that
    // is under somebody's finger.
    final id = await context.registerDirectory(
      path: folder.path,
      displayName: 'ridge',
    );
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');
    await tester.tap(find.byKey(const Key('thread-context')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.byKey(ContextPanelBody.toggleKeyFor(id)), findsOneWidget);

    await recordActivity();
    // Asserted on every frame the reload passes through rather than only on
    // the one it settles at: a switch gone for a single frame is a switch
    // gone from under a finger.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      expect(spinner(), findsNothing, reason: 'frame $i');
      expect(
        find.byKey(ContextPanelBody.toggleKeyFor(id)),
        findsOneWidget,
        reason: 'frame $i',
      );
    }
    await settleQueues(tester);
  });

  testWidgets('the ✕ closes it and leaves the thread where it was',
      (tester) async {
    await context.registerDirectory(path: folder.path, displayName: 'ridge');
    await seedThread('c1', 'Homepage copy');
    await pumpInbox(tester);
    await openThread(tester, 'Send the survey back');
    await tester.tap(find.byKey(const Key('thread-context')));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(panel(), findsOneWidget);

    await tester.tap(find.byKey(SidePanelHost.closeKey));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    expect(panel(), findsNothing);
    expect(find.byType(SidePanelHost), findsNothing);
    await settleQueues(tester);
  });

  group('the doors into one file', () {
    /// A registered directory holding one file with words in it.
    Future<({String dirId, int fileId})> seedFile() async {
      final dirId = await context.registerDirectory(
        path: folder.path,
        displayName: 'ridge',
      );
      final fileId = await context.upsertFile(
        dirId: dirId,
        relPath: 'docs/pricing.md',
        size: 400,
        mtime: '2026-09-09T09:00:00Z',
        sha256: 'sha-1',
        kind: 'doc',
        claudeChain: const [],
        textChars: 400,
      );
      await context.setFileText(fileId, 'Q4 rates hold at nine.');
      return (dirId: dirId, fileId: fileId);
    }

    Finder filePanel() => find.descendant(
          of: find.byType(SidePanelHost),
          matching: find.byType(ContextFilePanelBody),
        );

    testWidgets('a provenance chip opens the file the draft read',
        (tester) async {
      final seeded = await seedFile();
      await seedThread('c1', 'Homepage copy');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'c1-m1',
        body: 'Friday works.',
        contextJson: DraftProvenance(
          documents: const [],
          directories: const ['ridge'],
          files: [
            (
              dir: 'ridge',
              path: 'docs/pricing.md',
              locator: 'Pricing',
              fileId: seeded.fileId,
            ),
          ],
          skills: const [],
        ).encode(),
      );
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');

      // The caption names what was read; the chip is the door to it.
      await tester.tap(find.descendant(
        of: find.byKey(InboxScreen.useSuggestionKey),
        matching: find.text('Use it'),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      await tester.tap(
        find.byKey(Composer.provenanceChipKeyFor(seeded.fileId)),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      expect(filePanel(), findsOneWidget);
      // Named by the file, with the project and the path under it.
      expect(find.text('pricing.md'), findsOneWidget);
      expect(find.text('ridge/docs/pricing.md'), findsWidgets);
      await settleQueues(tester);
    });

    testWidgets('a fourth file the caption never named gets no chip',
        (tester) async {
      final seeded = await seedFile();
      final ids = <int>[seeded.fileId];
      for (final name in ['docs/terms.md', 'docs/scope.md', 'docs/notes.md']) {
        ids.add(await context.upsertFile(
          dirId: seeded.dirId,
          relPath: name,
          size: 100,
          mtime: '2026-09-09T09:00:00Z',
          sha256: 'sha-$name',
          kind: 'doc',
          claudeChain: const [],
          textChars: 100,
        ));
      }
      await seedThread('c1', 'Homepage copy');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'c1-m1',
        body: 'Friday works.',
        contextJson: DraftProvenance(
          documents: const [],
          directories: const ['ridge'],
          files: [
            for (final id in ids)
              (dir: 'ridge', path: 'docs/f$id.md', locator: '', fileId: id),
          ],
          skills: const [],
        ).encode(),
      );
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');
      await tester.tap(find.descendant(
        of: find.byKey(InboxScreen.useSuggestionKey),
        matching: find.text('Use it'),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }

      // The chips are the caption's names made tappable, and the caption stops
      // at three — a fourth chip would be a door to a file the sentence above
      // it never named.
      for (final id in ids.take(DraftProvenance.maxFiles)) {
        expect(find.byKey(Composer.provenanceChipKeyFor(id)), findsOneWidget);
      }
      expect(
        find.byKey(Composer.provenanceChipKeyFor(ids.last)),
        findsNothing,
      );
      await settleQueues(tester);
    });

    testWidgets('Files › on the Context panel opens the same file beside',
        (tester) async {
      final seeded = await seedFile();
      await seedThread('c1', 'Homepage copy');
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');
      await tester.tap(find.byKey(const Key('thread-context')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      await tester.tap(find.byKey(ContextPanelBody.filesKeyFor(seeded.dirId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.text('docs/pricing.md'), findsOneWidget);

      await tester.tap(find.byKey(ContextPanelBody.fileKeyFor(seeded.fileId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      // The side shows one thing: the file REPLACES the panel that named it.
      expect(filePanel(), findsOneWidget);
      expect(panel(), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('Consult asks for a draft that reads this file first',
        (tester) async {
      final seeded = await seedFile();
      await seedThread('c1', 'Homepage copy');
      // Linked, because Consult is offered only where the retriever would
      // actually quote the file — see the test under this one.
      await context.link(
        seeded.dirId,
        ContextScopeKind.thread,
        'email',
        'c1',
      );
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');
      await tester.tap(find.byKey(const Key('thread-context')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.filesKeyFor(seeded.dirId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.fileKeyFor(seeded.fileId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      await tester.tap(find.byKey(ContextFilePanelBody.consultKey));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      final work = (await db
              .customSelect("SELECT task_kind, entity_id, payload_json "
                  "FROM work_items WHERE task_kind = 'draft'")
              .get())
          .single
          .data;
      expect(work['entity_id'], 'c1-m1');
      expect(
        work['payload_json'],
        '{"context_file_ids":[${seeded.fileId}]}',
      );
      await settleQueues(tester);
    });

    testWidgets('a directory this room does not read offers no Consult',
        (tester) async {
      // The whole library gets a `Files ›`, linked or not, so a file of a
      // directory this room never switched on is one tap away. The retriever
      // re-checks scope and would drop it, so the button would press and
      // change nothing — the sentence names the switch instead.
      final seeded = await seedFile();
      await seedThread('c1', 'Homepage copy');
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');
      await tester.tap(find.byKey(const Key('thread-context')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.filesKeyFor(seeded.dirId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.fileKeyFor(seeded.fileId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      expect(filePanel(), findsOneWidget);
      expect(find.byKey(ContextFilePanelBody.consultKey), findsNothing);
      expect(
        find.byKey(ContextFilePanelBody.consultNoteKey),
        findsOneWidget,
      );
      expect(
        find.text('Not linked to this room — switch «ridge» on under '
            'Context to consult it.'),
        findsOneWidget,
      );

      // Switch the directory on and come back: the same file, the same door,
      // and now a button that means something. The disclosure is a
      // preference of the panel, so it is still open.
      await tester.tap(find.byKey(SidePanelHost.closeKey));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('thread-context')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.toggleKeyFor(seeded.dirId)));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.fileKeyFor(seeded.fileId)));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(find.byKey(ContextFilePanelBody.consultKey), findsOneWidget);
      expect(find.byKey(ContextFilePanelBody.consultNoteKey), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('a storyline the thread is in is scope enough for Consult',
        (tester) async {
      // The room's own links are half the question; what it inherits is the
      // other half, and the retriever reads both. A file offered here must
      // be one the retriever would actually quote.
      final seeded = await seedFile();
      await seedThread('c1', 'Homepage copy');
      await store.insertStoryline(
        id: 'sl-1',
        title: 'Website redesign',
        status: 'active',
        createdBy: 'auto',
      );
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await context.link(seeded.dirId, ContextScopeKind.storyline, '', 'sl-1');
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');
      await tester.tap(find.byKey(const Key('thread-context')));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.filesKeyFor(seeded.dirId)));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      await tester.tap(find.byKey(ContextPanelBody.fileKeyFor(seeded.fileId)));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(find.byKey(ContextFilePanelBody.consultKey), findsOneWidget);
      expect(find.byKey(ContextFilePanelBody.consultNoteKey), findsNothing);
      await settleQueues(tester);
    });

    testWidgets('an activity row leaves the reader on the passage',
        (tester) async {
      // The file panel's providers watch the activity stream too, and a
      // spinner here would not only blank the words: rebuilding the body
      // re-runs its post-frame `ensureVisible`, yanking a reader who had
      // scrolled away back to the highlight once a minute.
      final seeded = await seedFile();
      await context.replaceChunks(seeded.fileId, const [
        (
          seq: 0,
          locator: 'Pricing',
          text: 'docs/pricing.md · Pricing\nQ4 rates hold at nine.',
        ),
      ]);
      await seedThread('c1', 'Homepage copy');
      await store.upsertDraft(
        source: 'email',
        conversationKey: 'c1',
        replyToMessageId: 'c1-m1',
        body: 'Friday works.',
        contextJson: DraftProvenance(
          documents: const [],
          directories: const ['ridge'],
          files: [
            (
              dir: 'ridge',
              path: 'docs/pricing.md',
              locator: 'Pricing',
              fileId: seeded.fileId,
            ),
          ],
          skills: const [],
        ).encode(),
      );
      await pumpInbox(tester);
      await openThread(tester, 'Send the survey back');
      await tester.tap(find.descendant(
        of: find.byKey(InboxScreen.useSuggestionKey),
        matching: find.text('Use it'),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      await tester.tap(
        find.byKey(Composer.provenanceChipKeyFor(seeded.fileId)),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(find.byKey(ContextFilePanelBody.locatedKey), findsOneWidget);
      // The header names the file, not the placeholder it falls back to.
      expect(find.text('pricing.md'), findsOneWidget);

      await recordActivity();
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        expect(spinner(), findsNothing, reason: 'frame $i');
        expect(
          find.byKey(ContextFilePanelBody.locatedKey),
          findsOneWidget,
          reason: 'frame $i',
        );
        expect(find.text('pricing.md'), findsOneWidget, reason: 'frame $i');
      }
      await settleQueues(tester);
    });
  });
}
