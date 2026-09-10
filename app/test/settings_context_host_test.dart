import 'dart:io';

import 'package:bond_inbox/data/context_store.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/ai_worker.dart';
import 'package:bond_inbox/services/context/directory_access.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/settings_context_section.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Context directories as the SCREEN wires them: a real store behind the
/// section, a real work queue in front of it, and a folder that actually
/// exists on this disk.
///
/// `settings_context_section_test.dart` pins what the section does with the
/// rows it is handed. This pins the wiring — that Add registers a row and
/// queues the read, that Remove takes it away again, and that the section is
/// on both stops.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
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

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    context = ContextStore(db);
    folder = Directory.systemTemp.createTempSync('bond-context-host');
    File('${folder.path}/CLAUDE.md').writeAsStringSync('# acme\n\nnotes\n');
    dialogs = _FakeDialogs(folder.path);
  });

  tearDown(() async {
    await db.close();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  Future<void> pumpInbox(
    WidgetTester tester, {
    RailSection section = RailSection.needsYou,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(section),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        // No Runner behind a `flutter test` binary: the real channel would
        // answer MissingPluginException, and the seam's whole point is that
        // this answer is a legal one.
        directoryAccessProvider.overrideWithValue(const PlainDirectoryAccess()),
        // A worker with no handlers: Add pumps the queue, and the real
        // reconcile handler would then walk a folder and reach for the
        // embedding server inside a widget test. What this test is pinning is
        // that the ROW is written on `local` — `context_reconcile_handler_
        // test.dart` is where the pass itself runs.
        aiWorkerProvider.overrideWithValue(
          AiWorker(store, handlers: const []),
        ),
      ],
      child: MaterialApp(home: InboxScreen(fileDialogs: dialogs)),
    ));
    // Bounded pumps rather than a settle: the screen owns a sixty-second
    // periodic timer and an unbounded settle would never come back.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Settings lives in the icon rail's account menu, so getting there is two
  /// taps. The menu is a route, hence the 400 ms pumps.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(IconRail.settingsItemKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> expandContext(WidgetTester tester) async {
    final toggle =
        find.byKey(SettingsSection.toggleKey(ContextDirectoriesSection.title));
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Add registers the folder and queues the read', (tester) async {
    await pumpInbox(tester);
    await openSettings(tester);
    expect(find.text('No directories yet'), findsOneWidget);

    await expandContext(tester);
    final add = find.byKey(ContextDirectoriesSection.addKey);
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    // One for the tap, then one per round trip the register makes.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final dirs = await context.directories();
    expect(dirs, hasLength(1));
    expect(dirs.single.path, folder.path);

    // Enqueued on source `local`, which is the source `AiWorker._sources`
    // had to gain — without it the row would sit pending for ever.
    expect(
      await store.workCounts('context_reconcile', sources: const ['local']),
      isNotEmpty,
    );

    // And the row is on the screen, named for the folder.
    await tester.pump();
    expect(
      find.byKey(ContextDirectoriesSection.rowKeyFor(dirs.single.id)),
      findsOneWidget,
    );
    expect(find.text(folder.path), findsOneWidget);
  });

  testWidgets('the two-tap Remove takes the row away', (tester) async {
    final id = await context.registerDirectory(
      path: folder.path,
      displayName: 'acme',
    );
    await pumpInbox(tester);
    await openSettings(tester);
    await expandContext(tester);
    expect(
      find.byKey(ContextDirectoriesSection.rowKeyFor(id)),
      findsOneWidget,
    );

    final remove = find.byKey(ContextDirectoriesSection.removeKeyFor(id));
    await tester.ensureVisible(remove);
    await tester.pump();
    await tester.tap(remove);
    await tester.pump();

    final confirm =
        find.byKey(ContextDirectoriesSection.confirmRemoveKeyFor(id));
    await tester.ensureVisible(confirm);
    await tester.pump();
    await tester.tap(confirm);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(await context.directories(), isEmpty);
    expect(find.byKey(ContextDirectoriesSection.rowKeyFor(id)), findsNothing);
  });

  testWidgets('the section is on the AI stop too', (tester) async {
    await context.registerDirectory(path: folder.path, displayName: 'acme');
    // The AI stop is a SECTION, not an overlay: standing on it renders the
    // same screen under SettingsScope.ai with no account menu involved.
    await pumpInbox(tester, section: RailSection.ai);
    await tester.pump();

    expect(find.text(ContextDirectoriesSection.title), findsOneWidget);
    // Under the AI scope the account-only sections stay behind the menu.
    expect(find.text('Sync & data'), findsNothing);
  });
}
