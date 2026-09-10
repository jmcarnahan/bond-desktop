import 'dart:async';
import 'dart:io';

import 'package:bond_inbox/data/app_paths.dart';
import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/setup_store.dart';
import 'package:bond_inbox/models/setup_step.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/notification_provider.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/setup/setup_flow.dart';
import 'package:bond_inbox/services/models/download_state.dart';
import 'package:bond_inbox/services/models/model_manifest.dart';
import 'package:bond_inbox/services/notify/desktop_notification_service.dart';
import 'package:bond_inbox/services/notify/settled_event.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/system/system_info.dart';
import 'package:bond_inbox/widgets/pane_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_auth_session.dart';
import 'fixtures/fake_desktop_notifier.dart';
import 'fixtures/fake_process_runner.dart';
import 'fixtures/fake_system_info.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// A store whose writes fail — the Finish that cannot be saved.
class _UnwritableStore extends SetupStore {
  _UnwritableStore(super.db);

  @override
  Future<void> set(String key, String value) async =>
      throw StateError('disk is read-only');
}

/// The whole wizard, walked end to end.
///
/// The models are seeded as ALREADY DOWNLOADED — a ledger saying done and
/// three files on disk — so this file is about the walk rather than about the
/// downloader, which has its own suite. Everything real is built in `setUp`,
/// because a `testWidgets` body runs in a fake-async zone where a filesystem
/// future never completes.
void main() {
  late Directory support;
  late BondDatabase db;
  late SetupStore store;
  late FakeSystemInfo system;
  late FakeAuthSession auth;
  late FakeDesktopNotifier notifier;
  late FakeProcessRunner runner;
  late ModelServerSupervisor supervisor;
  late StreamController<MessageSettled> settles;
  late DesktopNotificationService notifications;
  late ProviderContainer container;
  late ModelManifest manifest;

  String folder() => p.join(support.path, 'models');

  /// The wizard's world. [overStore] is for the one case that needs a store
  /// which cannot be written.
  void makeContainer({SetupStore? overStore}) {
    container = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      // The models folder is `AppPaths.models` with the preference left
      // empty, which is what an untouched install really has.
      appPathsProvider.overrideWithValue(AppPaths(support)),
      modelManifestProvider.overrideWithValue(manifest),
      systemInfoProvider.overrideWithValue(system),
      modelServerSupervisorProvider.overrideWithValue(supervisor),
      authSessionProvider.overrideWithValue(auth),
      desktopNotifierProvider.overrideWithValue(notifier),
      desktopNotificationServiceProvider.overrideWithValue(notifications),
      if (overStore != null) setupStoreProvider.overrideWithValue(overStore),
    ]);
    addTearDown(container.dispose);
  }

  setUp(() async {
    support = await Directory.systemTemp.createTemp('bond-flow');
    db = testDb();
    store = SetupStore(db);
    manifest = testManifest();
    system = FakeSystemInfo()
      ..hardwareInfo = const HardwareInfo(
        chip: 'Apple M3 Max',
        memoryBytes: 68719476736,
        appleSilicon: true,
        rosetta: false,
        osVersion: '15.6',
      )
      ..free = 200 * 1024 * 1024 * 1024;
    auth = FakeAuthSession(signedIn: true);
    notifier = FakeDesktopNotifier();
    runner = FakeProcessRunner();
    settles = StreamController<MessageSettled>.broadcast();
    notifications = DesktopNotificationService(
      events: settles.stream,
      notifier: notifier,
      enabled: () => false,
    );
    supervisor = ModelServerSupervisor(
      runner: runner,
      supportDir: support,
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => manifest.toPreset(folder()),
      routerPort: () => 8080,
      // Off, so Finish's fire-and-forget `ensureRunning` is the no-op it is
      // on every machine that has not opted in yet. What Finish is tested for
      // here is the PREFERENCE it writes.
      managed: () => false,
    );

    // The set, already here: a ledger saying done and three files on disk.
    var ledger = DownloadLedger.empty;
    for (final model in manifest.models) {
      final file = File(p.join(folder(), model.relativePath));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(model.sizeBytes, 7));
      ledger = ledger.record(FileDownloadState(
        id: model.id,
        status: DownloadStatus.done,
        receivedBytes: model.sizeBytes,
        totalBytes: model.sizeBytes,
        sha256: model.sha256,
      ));
    }
    await store.recordDownload(ledger);

    makeContainer();
  });

  tearDown(() async {
    notifications.dispose();
    await settles.close();
    await supervisor.dispose();
    await db.close();
    if (support.existsSync()) await support.delete(recursive: true);
  });

  var finishes = 0;

  /// Three bare pumps — the idiom this suite uses wherever an indeterminate
  /// progress indicator can be on screen and `pumpAndSettle` would never
  /// return.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester) async {
    finishes = 0;
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SetupFlow(onFinished: () => finishes++),
      ),
    ));
    await settle(tester);
  }

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(SetupFlow.continueKey));
    await tester.tap(find.byKey(SetupFlow.continueKey));
    await settle(tester);
  }

  /// The arrow itself, not the tooltip wrapped around it — `byTooltip` finds
  /// the wrapper, and the disabled state lives on the button.
  bool backEnabled(WidgetTester tester) => tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_back),
          )
          .onPressed !=
      null;

  testWidgets('the whole walk, welcome to finish', (tester) async {
    await mount(tester);

    // 1 — Welcome. Nowhere to go back to, and the button says so.
    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(find.text('Step 1 of 8'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    expect(backEnabled(tester), isFalse);

    await tapContinue(tester);

    // 2 — Your Mac.
    expect(find.text('Your Mac'), findsOneWidget);
    expect(find.text('Step 2 of 8'), findsOneWidget);
    expect(find.text('Apple M3 Max'), findsOneWidget);
    expect(find.text('64.0 GB'), findsOneWidget);
    expect(backEnabled(tester), isTrue);
    expect(await store.get(SetupStore.setupKey), 'device');

    await tapContinue(tester);

    // 3 — Models.
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Step 3 of 8'), findsOneWidget);
    expect(find.text('Finds related messages'), findsOneWidget);

    await tapContinue(tester);

    // 4 — Storage. Everything is already here, so there is nothing to fit.
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Step 4 of 8'), findsOneWidget);
    expect(find.text(folder()), findsOneWidget);
    expect(find.text('All models are already in this folder.'), findsOneWidget);

    await tapContinue(tester);

    // 5 — Download. A seeded set starts no run at all.
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Step 5 of 8'), findsOneWidget);
    expect(find.text('All models are on this Mac.'), findsOneWidget);
    expect(find.text('Ready'), findsNWidgets(3));

    await tapContinue(tester);

    // 6 — Sign in. Already signed in, so one sentence and a Continue.
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Step 6 of 8'), findsOneWidget);
    expect(find.text("You're signed in."), findsOneWidget);
    expect(find.text('Bond Inbox'), findsNothing);

    await tapContinue(tester);

    // 7 — Notifications. The press is the ask.
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Step 7 of 8'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(notifier.authorizeCalls, 0);

    await tapContinue(tester);

    expect(notifier.authorizeCalls, 1);

    // 8 — All set.
    expect(find.text('All set'), findsOneWidget);
    expect(find.text('Step 8 of 8'), findsOneWidget);
    expect(find.text('Bond is ready.'), findsOneWidget);
    expect(find.text(folder()), findsOneWidget);
    expect(find.text('Bond runs it on port 8080'), findsOneWidget);
    expect(find.text('Jared'), findsOneWidget);
    expect(find.text('on'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
    // The step recorded on ARRIVAL here is the one before it. `done` is the
    // gate's sentinel and only Finish writes it, so a quit on this screen
    // resumes on Notifications rather than letting the next launch past the
    // gate with the managed server still off.
    expect(await store.get(SetupStore.setupKey), 'notifications');

    await tapContinue(tester);

    expect(finishes, 1);
    expect(await store.get(SetupStore.setupKey), 'done');
    expect(container.read(appPrefsProvider).managedServer, isTrue);
  });

  testWidgets('signed out, the sign-in step is the only way past itself',
      (tester) async {
    // The fixture's flag is public so a test can be the other person: a
    // keychain with nothing in it yet, which is what a real first run has.
    auth.signedIn = false;

    await mount(tester);
    for (var step = 0; step < 5; step++) {
      await tapContinue(tester);
    }

    expect(find.text('Step 6 of 8'), findsOneWidget);
    expect(
      find.text('Sign in to your Bond workspace to read your mail.'),
      findsOneWidget,
    );
    // No Continue at all: signing in is what advances the step, and a button
    // beside it would offer a way past the one thing this step is for.
    expect(find.byKey(SetupFlow.continueKey), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    // Signing in advances rather than re-probing: the session answered a
    // microsecond ago.
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Step 7 of 8'), findsOneWidget);
    expect(auth.signIns, 1);
  });

  testWidgets('a Finish that cannot be saved keeps the step and says so',
      (tester) async {
    makeContainer(overStore: _UnwritableStore(db));
    await mount(tester);
    for (var step = 0; step < 7; step++) {
      await tapContinue(tester);
    }
    expect(find.text('All set'), findsOneWidget);

    await tapContinue(tester);

    // The wizard does not hand over an inbox whose setup is not on disk: the
    // gate would only show the flow again, from the top.
    expect(finishes, 0);
    expect(find.text('All set'), findsOneWidget);
    expect(
      find.text('Setup could not be saved. Try Finish again.'),
      findsOneWidget,
    );
  });

  testWidgets('Back walks the steps in reverse and persists as it goes',
      (tester) async {
    await mount(tester);
    await tapContinue(tester);
    await tapContinue(tester);
    expect(find.text('Step 3 of 8'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    expect(find.text('Your Mac'), findsOneWidget);
    expect(await store.get(SetupStore.setupKey), 'device');

    await tester.tap(find.byTooltip('Back'));
    await settle(tester);

    expect(find.text('Welcome to Bond'), findsOneWidget);
    expect(backEnabled(tester), isFalse);
    expect(await store.get(SetupStore.setupKey), 'welcome');
  });

  testWidgets('the pane carries the step title and the counter', (tester) async {
    await mount(tester);

    // One pane, not eight screens: the title and the count are the chrome,
    // and the step is what changes inside it.
    expect(find.byType(PaneSurface), findsOneWidget);
    expect(find.text(SetupStep.welcome.title), findsOneWidget);
  });
}
