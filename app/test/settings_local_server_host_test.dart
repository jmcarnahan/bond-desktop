import 'dart:io';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/services/server/model_server_supervisor.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/settings_local_server_card.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures/fake_process_runner.dart';
import 'fixtures/test_db.dart';
import 'fixtures/test_manifest.dart';

/// The Local server card wired to the real host.
///
/// `settings_local_server_test.dart` drives the card over closures; this pins
/// the WIRES — that the switch and the port field move the preference, and
/// that the supervisor is asked for a server only afterwards. The order is the
/// whole subject: the supervisor reads `managedServer` and `routerPort`
/// through callbacks every time it is asked, so a host that called it first
/// would start a server against the values the user has just replaced, and
/// nothing downstream would ever say so.
///
/// **Bounded pumps only.** `InboxScreen` owns a sixty-second periodic timer,
/// so a `pumpAndSettle` anywhere in this file would never come back.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// A supervisor that records what it was asked for, and what the preferences
/// said AT THAT MOMENT.
///
/// A real one over a fake runner would spawn nothing either, but it would do
/// real filesystem work — a pid file, a preset, a log — and a real future
/// never completes inside the fake-async zone a `testWidgets` body runs in.
/// What is under test here is an ORDER, and the order is exactly what these
/// three lines capture.
class _RecordingSupervisor extends ModelServerSupervisor {
  _RecordingSupervisor({
    required super.runner,
    required super.supportDir,
    required super.binaryPath,
    required super.buildPreset,
    required super.routerPort,
    required super.managed,
  });

  final List<String> calls = [];

  @override
  Future<void> ensureRunning() async =>
      calls.add('ensureRunning managed=${managed()} port=${routerPort()}');

  @override
  Future<void> stop() async => calls.add('stop managed=${managed()}');

  @override
  Future<void> restart() async =>
      calls.add('restart managed=${managed()} port=${routerPort()}');
}

void main() {
  late BondDatabase db;
  late MessageStore store;
  late _RecordingSupervisor supervisor;

  /// The live container, which does not exist until the tree is pumped. The
  /// supervisor's two preference callbacks read through it, exactly as the
  /// real `modelServerSupervisorProvider` reads through its own `ref` — that
  /// LATE binding is what makes "the pref moved first" observable at all.
  ProviderContainer? container;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
    // A path, not a directory: nothing below writes, and creating one would be
    // filesystem work this test has no use for.
    final support = Directory(
      p.join(Directory.systemTemp.path, 'bond-local-server-host'),
    );
    supervisor = _RecordingSupervisor(
      runner: FakeProcessRunner(),
      supportDir: support,
      binaryPath: () => '/usr/bin/true',
      buildPreset: () => testPreset(support.path),
      routerPort: () =>
          container?.read(appPrefsProvider).routerPort ??
          AppPrefs.defaultRouterPort,
      managed: () => container?.read(appPrefsProvider).managedServer ?? false,
    );
    container = null;
  });

  tearDown(() async {
    await supervisor.dispose();
    await db.close();
  });

  Future<void> pumpInbox(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        modelServerSupervisorProvider.overrideWithValue(supervisor),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    await tester.pump();
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(InboxScreen)),
    );
  }

  Future<void> openModels(WidgetTester tester) async {
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(IconRail.settingsItemKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final toggle = find.byKey(SettingsSection.toggleKey('Models'));
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    // Past the section's expand animation, in bounded steps: `pumpAndSettle`
    // never comes back with InboxScreen's sixty-second timer running.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final target = find.byKey(key);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the switch writes the preference before it asks for a server',
      (tester) async {
    await pumpInbox(tester);
    await openModels(tester);

    await tapKey(tester, SettingsLocalServerBody.managedKey);

    expect(await store.getPref(managedServerKey), 'true');
    // `managed=true` is the assertion, not the call itself: the supervisor
    // asks the preference at the top of `ensureRunning`, so a host that
    // started the server first would have left `false` here and spawned
    // nothing at all.
    expect(supervisor.calls, ['ensureRunning managed=true port=8080']);
  });

  testWidgets('turning it off stops the server against the new preference',
      (tester) async {
    await store.setPref(managedServerKey, 'true');
    await pumpInbox(tester);
    await openModels(tester);

    await tapKey(tester, SettingsLocalServerBody.managedKey);

    expect(await store.getPref(managedServerKey), 'false');
    // The same ordering from the other side: `stop` emits `ServerDisabled`
    // rather than `ServerStopped` only because the preference is already off
    // when it runs.
    expect(supervisor.calls, ['stop managed=false']);
  });

  /// The port, through the closure the host handed the card.
  ///
  /// Not through the button: once the Models section is expanded the card is
  /// its header, and the Save control sits where the pane's own chrome
  /// overlaps it, so a `tap` there lands on nothing and would pass for the
  /// wrong reason. That the BUTTON calls `onPortSaved` is pinned in
  /// `settings_local_server_test.dart`; what only this file can see is what
  /// the host does when it is called.
  testWidgets('a saved port lands in prefs, and the restart is onto it',
      (tester) async {
    await store.setPref(managedServerKey, 'true');
    await pumpInbox(tester);
    await openModels(tester);

    tester
        .widget<SettingsLocalServerBody>(
          find.byType(SettingsLocalServerBody),
        )
        .onPortSaved(9310);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(await store.getPref(routerPortKey), '9310');
    // A running server cannot change the socket it is bound to, so the restart
    // IS the setting taking effect — and it has to happen after the write, or
    // the server comes back on the port the user just left.
    expect(supervisor.calls, ['restart managed=true port=9310']);
  });
}
