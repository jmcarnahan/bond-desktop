import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/screens/inbox_screen.dart';
import 'package:bond_inbox/screens/settings_host.dart';
import 'package:bond_inbox/services/attachments/file_dialogs.dart';
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The settings surface as its own host.
///
/// `settings_models_host_test.dart` and its siblings pump the REAL inbox and
/// reach the pane through the rail; they are the acceptance tests for the
/// extraction and they did not change. This file pins what is new: that the
/// host owns the probe, that the two seams the inbox kept are the two the host
/// calls out to, and that both rungs render from one widget.
///
/// **Bounded pumps only.** The last case pumps `InboxScreen`, which owns a
/// sixty-second periodic timer, so nothing here may `pumpAndSettle`.

class _FakeSync implements MailSync {
  @override
  Future<void> syncNow() async {}

  @override
  Future<void> ensureBodies(String conversationKey) async {}

  @override
  Future<void> ensureMessageBody(String sourceMessageId) async {}
}

/// An open panel nobody in this file presses.
class _NoDialogs implements FileDialogs {
  @override
  Future<String?> chooseSaveLocation({required String suggestedName}) async =>
      null;

  @override
  Future<String?> chooseDirectory() async => null;
}

/// A probe that never reaches a socket and counts the closes.
///
/// A subclass rather than an interface: [ModelServerProbe] is a plain class
/// whose two members are both overridable, and a new abstraction for one
/// counter would be a wider change than the thing it tests.
class _CountingProbe extends ModelServerProbe {
  int closes = 0;

  @override
  Future<ModelProbeResult> probe(String completionsUrl, {String? bearer}) async =>
      const ModelProbeResult(reachable: true, modelIds: ['a-model']);

  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// What the host itself recorded, so a case can read the seams rather than
  /// the widgets they moved.
  final processingSetTo = <bool>[];
  final toasts = <String>[];
  var thumbnailsForgotten = 0;
  var settleWaits = 0;
  Completer<void>? settleGate;

  setUp(() {
    processingSetTo.clear();
    toasts.clear();
    thumbnailsForgotten = 0;
    settleWaits = 0;
    settleGate = null;
  });

  Future<ProviderContainer> pumpHost(
    WidgetTester tester, {
    SettingsScope scope = SettingsScope.all,
    ModelServerProbe? probe,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        // The two platform channels a widget test has nobody on the other end
        // of — `settings_models_host_test.dart`'s list, minus the inbox's own
        // initial section.
        appInfoProvider.overrideWith((ref) async => (
              version: '1.2.3',
              build: '4',
            )),
        databasePathProvider.overrideWith((ref) async => '/tmp/bond_inbox.db'),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SettingsHost(
            scope: scope,
            onBack: () {},
            onHome: () {},
            onCloseSettings: () {},
            fileDialogs: _NoDialogs(),
            onSetProcessing: (on) async => processingSetTo.add(on),
            waitForPullsToSettle: () async {
              settleWaits++;
              await settleGate?.future;
            },
            onRefreshNow: () async {},
            onSignOut: () async {},
            onOpenActivityLog: () {},
            onForgetThumbnails: () => thumbnailsForgotten++,
            onToast: toasts.add,
            probe: probe,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(SettingsHost)),
    );
  }

  Future<void> openSection(WidgetTester tester, String title) async {
    final toggle = find.byKey(SettingsSection.toggleKey(title));
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the host owns one probe and closes it with the pane',
      (tester) async {
    final probe = _CountingProbe();
    await pumpHost(tester, probe: probe);

    expect(probe.closes, 0);

    // The pane goes, and the client goes with it. Anything else is a
    // connection pool per visit to Settings.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(probe.closes, 1);
  });

  testWidgets('the Processing switch calls the injected setter',
      (tester) async {
    // Off to start with, so the flip under test is the interesting direction
    // and the two resets below are live rather than inert.
    await store.setPref(processingOnKey, 'false');
    final container = await pumpHost(tester);
    await openSection(tester, 'Processing');

    await tapKey(tester, SettingsScreen.processingToggleKey);

    expect(processingSetTo, [true]);
    // And the host wrote nothing itself: the session flag belongs to the
    // inbox, which is the screen the sidebar's own switch is on.
    expect(container.read(processingProvider), isFalse);
  });

  testWidgets('a reset waits for the pulls to settle before it invalidates',
      (tester) async {
    // A reset refuses outright while the switch is on, so this seeds the
    // preference off rather than pressing the switch first.
    await store.setPref(processingOnKey, 'false');
    await store.upsertMessage({
      'source': 'email',
      'source_message_id': 'm1',
      'conversation_key': 'conv-1',
      'direction': 'inbound',
      'subject': 'Invoice 4471 is overdue',
      'from_name': 'Sarah',
      'from_address': 'sarah@example.com',
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'body_text': 'Body of m1',
      'triage_status': 'pending',
    });
    await store.enqueueWork('extract', 'email', 'm1');
    expect(await store.workCounts('extract'), {'pending': 1});

    settleGate = Completer<void>();
    await pumpHost(tester);
    await openSection(tester, 'Processing');

    // The two-step IS the confirmation — there is no dialog to answer.
    await tapKey(tester, SettingsScreen.clearAiResultsKey);
    await tapKey(tester, SettingsScreen.clearAiResultsConfirmKey);

    expect(settleWaits, 1);
    // Still there: the reset is parked on the inbox's own pull flags, which
    // is the whole point of the seam.
    expect(await store.workCounts('extract'), {'pending': 1});

    settleGate!.complete();
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(await store.workCounts('extract'), isEmpty);
    expect(thumbnailsForgotten, 1);
  });

  testWidgets('the full scope renders every section', (tester) async {
    await pumpHost(tester);

    for (final title in ['About me', 'Models', 'Needs You', 'Processing']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Sync & data'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
  });

  testWidgets('the AI scope renders only its subset', (tester) async {
    await pumpHost(tester, scope: SettingsScope.ai);

    for (final title in ['About me', 'Models', 'Needs You', 'Processing']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // The account's own half stays behind the avatar menu.
    expect(find.text('Sync & data'), findsNothing);
    expect(find.text('About'), findsNothing);
    expect(find.text('Notifications'), findsNothing);
  });

  testWidgets('the inbox seats the host at both rungs, each with its scope',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final prefs = await AppPrefsNotifier.read(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        initialSectionProvider.overrideWithValue(RailSection.needsYou),
        initialAppPrefsProvider.overrideWithValue(prefs),
        syncServiceProvider.overrideWithValue(_FakeSync()),
        appInfoProvider.overrideWith((ref) async => (
              version: '1.2.3',
              build: '4',
            )),
        databasePathProvider.overrideWith((ref) async => '/tmp/bond_inbox.db'),
      ],
      child: const MaterialApp(home: InboxScreen()),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SettingsHost), findsNothing);

    // The avatar menu's Settings: the whole pane.
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(IconRail.settingsItemKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SettingsHost), findsOneWidget);
    expect(
      tester.widget<SettingsHost>(find.byType(SettingsHost)).scope,
      SettingsScope.all,
    );

    // The rail's AI stop: the same host, the model half. Standing on the stop
    // clears the pane the menu opened, so this is one walk and not two.
    await tester.tap(find.byIcon(Icons.auto_awesome));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SettingsHost), findsOneWidget);
    expect(
      tester.widget<SettingsHost>(find.byType(SettingsHost)).scope,
      SettingsScope.ai,
    );
  });
}
