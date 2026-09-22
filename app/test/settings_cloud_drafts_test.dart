import 'package:bond_inbox/screens/consent_screen.dart'
    show CloudDraftsConsentPane;
import 'package:bond_inbox/services/llm/model_probe.dart';
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/model_servers_form.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The three cloud-draft controls on the settings screen: the standing switch
/// under Suggested replies, and the count and the cap under Processing.
///
/// The screen is a plain widget over closures, so this file pumps it alone —
/// which is what makes `pumpAndSettle` safe here and nowhere near
/// `InboxScreen`. What it pins is the shape of the promise: the switch cannot
/// be turned on with nowhere to send, the count and the cap read as one
/// sentence, the consent pane quotes the cap in force, and none of it is a
/// dialog.

/// Counts the routes anything here pushes. The house rule forbids a popup,
/// and every surface in this file is a pane inside the screen.
class _RouteCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    if (previous != null) pushes++;
  }
}

/// Somebody else's service on the big model's address, which is the one
/// thing that opens the pane. The only place this name appears.
const _openAiUrl = 'https://api.openai.com/v1/chat/completions';
const _smallUrl = 'https://box.example.com/bulk/v1/chat/completions';

void main() {
  late _RouteCounter routes;
  late List<bool> standingWrites;
  late List<int> capWrites;

  setUp(() {
    standingWrites = [];
    capWrites = [];
  });

  Future<void> open(
    WidgetTester tester, {
    String? section,
    bool cloudDraftsStanding = false,
    ValueChanged<bool>? onCloudDraftsStandingChanged,
    String? improveTargetName,
    int? cloudDraftsToday,
    int cloudDraftsDailyCap = 50,
    ValueChanged<int>? onCloudDraftsDailyCapChanged,
    bool models = false,
    ModelPlacement placement = ModelPlacement.local,
    String boxBigUrl = '',
    String boxSmallUrl = '',
    Future<ModelProbeResult> Function(String, {String? bearer})? probe,
    Future<void> Function({
      required String bigUrl,
      required String smallUrl,
      required String bigModel,
      required String smallModel,
      String? bigKey,
      String? smallKey,
    })? onUseBox,
    Future<void> Function()? onCloudDraftsConsent,
    // A second pump into the SAME tree, to change a prop under a screen that
    // is already up: the sections keep their own open state across it, so
    // tapping the toggle again would close the one just opened.
    bool alreadyOpen = false,
  }) async {
    routes = _RouteCounter();
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [routes],
      home: Scaffold(
        body: SettingsScreen(
          threshold: 0.5,
          aboutMe: '',
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onBack: () {},
          onDraftPolicyChanged: (_) {},
          processingOn: false,
          onProcessingChanged: (_) {},
          cloudDraftsStanding: cloudDraftsStanding,
          onCloudDraftsStandingChanged: onCloudDraftsStandingChanged ??
              (on) => standingWrites.add(on),
          improveTargetName: improveTargetName,
          cloudDraftsToday: cloudDraftsToday,
          cloudDraftsDailyCap: cloudDraftsDailyCap,
          onCloudDraftsDailyCapChanged: onCloudDraftsDailyCapChanged ??
              (value) => capWrites.add(value),
          // Wired only for the consent case: the Models section needs a way
          // to connect behind it before it will render at all.
          modelPlacement: placement,
          boxBigUrl: boxBigUrl,
          boxSmallUrl: boxSmallUrl,
          probeServer: probe,
          onUseBox: models
              ? (onUseBox ??
                  ({
                    required bigUrl,
                    required smallUrl,
                    required bigModel,
                    required smallModel,
                    bigKey,
                    smallKey,
                  }) async {})
              : null,
          onCloudDraftsConsent: onCloudDraftsConsent,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    if (section == null || alreadyOpen) return;
    final toggle = find.byKey(SettingsSection.toggleKey(section));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  /// The screen with the standing switch deliberately unwired.
  Future<void> openUnwired(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          threshold: 0.5,
          aboutMe: '',
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onBack: () {},
          onDraftPolicyChanged: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final toggle = find.byKey(SettingsSection.toggleKey('Suggested replies'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  group('the standing switch', () {
    testWidgets('is absent when the host wires nothing', (tester) async {
      await openUnwired(tester);

      expect(find.byKey(SettingsScreen.cloudStandingKey), findsNothing);
      // The section it belongs to is still there, with the policy control.
      expect(find.text('When asked'), findsOneWidget);
    });

    testWidgets('sits under Suggested replies when it is wired',
        (tester) async {
      await open(
        tester,
        section: 'Suggested replies',
        improveTargetName: 'Claude',
      );

      expect(find.byKey(SettingsScreen.cloudStandingKey), findsOneWidget);
      expect(
        find.text('Improve drafts for messages that need you and are urgent'),
        findsOneWidget,
      );
    });

    testWidgets('is inert with nowhere to send, and says where to point it',
        (tester) async {
      await open(tester, section: 'Suggested replies');

      final toggle =
          tester.widget<Switch>(find.byKey(SettingsScreen.cloudStandingKey));
      expect(toggle.onChanged, isNull);
      expect(
        find.text(
            'Improve a draft has no server to run on. Check the Models section.'),
        findsOneWidget,
      );
    });

    testWidgets('names the target in its caption once there is one',
        (tester) async {
      await open(
        tester,
        section: 'Suggested replies',
        improveTargetName: 'Claude',
      );

      expect(
        find.text(
          'After the local draft is written, the same prompt goes to Claude '
          'and its answer replaces the draft. Counts toward the daily cap '
          'under Processing.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reports the flip to the host', (tester) async {
      await open(
        tester,
        section: 'Suggested replies',
        improveTargetName: 'Claude',
      );

      await tester.tap(find.byKey(SettingsScreen.cloudStandingKey));
      await tester.pumpAndSettle();

      expect(standingWrites, [true]);
      expect(
        tester
            .widget<Switch>(find.byKey(SettingsScreen.cloudStandingKey))
            .value,
        isTrue,
      );
    });

    testWidgets('follows the host when the rule is forced back off',
        (tester) async {
      // `AppPrefs.specForStage` and `applyPreset` can refuse a third-party
      // target and put the standing rule back off with nobody touching this
      // switch. It is seeded from the prop once, so without the resync in
      // `didUpdateWidget` it would go on reading on over a rule that is off.
      await open(
        tester,
        section: 'Suggested replies',
        improveTargetName: 'Claude',
        cloudDraftsStanding: true,
      );

      expect(
        tester
            .widget<Switch>(find.byKey(SettingsScreen.cloudStandingKey))
            .value,
        isTrue,
      );

      await open(
        tester,
        improveTargetName: 'Claude',
        cloudDraftsStanding: false,
        alreadyOpen: true,
      );

      expect(
        tester
            .widget<Switch>(find.byKey(SettingsScreen.cloudStandingKey))
            .value,
        isFalse,
      );
      // Adopting the host's own answer is not a flip, so nothing goes back.
      expect(standingWrites, isEmpty);
    });
  });

  group('the ledger line and the cap', () {
    testWidgets('are absent until the host has a count', (tester) async {
      await open(tester, section: 'Processing');

      expect(find.byKey(SettingsScreen.cloudLedgerKey), findsNothing);
      expect(find.byKey(SettingsScreen.cloudCapKey), findsNothing);
    });

    testWidgets('read as one sentence about today', (tester) async {
      await open(tester, section: 'Processing', cloudDraftsToday: 3);

      expect(find.text('Cloud drafts today: 3 of 50'), findsOneWidget);
      expect(
        find.text(
          'Drafts sent to a third-party target, by the Improve button, the '
          'standing rule, or a draft stage pointed at one. Nothing more goes '
          'today once the cap is reached.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the field opens on the cap in force', (tester) async {
      await open(
        tester,
        section: 'Processing',
        cloudDraftsToday: 0,
        cloudDraftsDailyCap: 200,
      );

      expect(
        tester
            .widget<TextField>(find.byKey(SettingsScreen.cloudCapKey))
            .controller!
            .text,
        '200',
      );
    });

    /// The same screen again with a different cap, the way the host rebuilds
    /// it after the notifier clamps: no section tap, no new observer.
    Future<void> rebuildWithCap(WidgetTester tester, int cap) async {
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [routes],
        home: Scaffold(
          body: SettingsScreen(
            threshold: 0.5,
            aboutMe: '',
            onThresholdChanged: (_) {},
            onAboutMeChanged: (_) {},
            onBack: () {},
            onDraftPolicyChanged: (_) {},
            processingOn: false,
            onProcessingChanged: (_) {},
            onCloudDraftsStandingChanged: (on) => standingWrites.add(on),
            cloudDraftsToday: 0,
            cloudDraftsDailyCap: cap,
            onCloudDraftsDailyCapChanged: (value) => capWrites.add(value),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    String capText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(SettingsScreen.cloudCapKey))
        .controller!
        .text;

    testWidgets('follows the host when it clamps what was typed',
        (tester) async {
      await open(tester, section: 'Processing', cloudDraftsToday: 0);

      await tester.enterText(find.byKey(SettingsScreen.cloudCapKey), '5000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(capWrites, [5000]);

      // The notifier clamps to a thousand and the host rebuilds with it.
      await rebuildWithCap(tester, 1000);

      expect(capText(tester), '1000');
      // And handing the same thousand back is not a second write.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(capWrites, [5000]);
    });

    testWidgets('but never overwrites a number still being typed',
        (tester) async {
      await open(tester, section: 'Processing', cloudDraftsToday: 0);

      await tester.enterText(find.byKey(SettingsScreen.cloudCapKey), '77');
      await rebuildWithCap(tester, 1000);

      expect(capText(tester), '77');
      expect(capWrites, isEmpty);
    });

    testWidgets('a submitted number reaches the host once', (tester) async {
      await open(tester, section: 'Processing', cloudDraftsToday: 0);

      await tester.enterText(find.byKey(SettingsScreen.cloudCapKey), '200');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(capWrites, [200]);
    });

    testWidgets('and so does one the reader simply typed and looked away from',
        (tester) async {
      await open(tester, section: 'Processing', cloudDraftsToday: 0);

      await tester.enterText(find.byKey(SettingsScreen.cloudCapKey), '7');
      // Focus leaves the field, which is the other way out of it. Back and
      // Home unmount it without ever moving focus, which is why the listener
      // is on the node rather than on a tap somewhere else.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(capWrites, [7]);
    });

    testWidgets('an emptied field changes nothing', (tester) async {
      await open(tester, section: 'Processing', cloudDraftsToday: 0);

      await tester.enterText(find.byKey(SettingsScreen.cloudCapKey), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(capWrites, isEmpty);
    });
  });

  group('the consent pane', () {
    /// The Models section open on a user-defined install whose BIG address is
    /// somebody else's service, with both servers answering one model each.
    Future<void> openConsent(
      WidgetTester tester, {
      required List<String> order,
      int cloudDraftsDailyCap = 50,
      Object? connectThrows,
      bool wireConsent = true,
    }) async {
      await open(
        tester,
        section: 'Models',
        models: true,
        placement: ModelPlacement.box,
        boxBigUrl: _openAiUrl,
        boxSmallUrl: _smallUrl,
        cloudDraftsDailyCap: cloudDraftsDailyCap,
        probe: (url, {bearer}) async => ModelProbeResult(
          reachable: true,
          modelIds: [url == _openAiUrl ? 'gpt-x' : 'qwen3-4b'],
        ),
        onCloudDraftsConsent:
            wireConsent ? () async => order.add('consent') : null,
        onUseBox: ({
          required bigUrl,
          required smallUrl,
          required bigModel,
          required smallModel,
          bigKey,
          smallKey,
        }) async {
          order.add('connect');
          if (connectThrows != null) throw connectThrows;
        },
      );

      final connect = find.byKey(ModelServersForm.connectKey);
      await tester.ensureVisible(connect);
      await tester.pumpAndSettle();
      await tester.tap(connect);
      await tester.pumpAndSettle();
    }

    testWidgets('Connect to a vendor asks first, and quotes the cap in force',
        (tester) async {
      final order = <String>[];
      await openConsent(tester, order: order, cloudDraftsDailyCap: 200);

      expect(find.byType(CloudDraftsConsentPane), findsOneWidget);
      expect(find.text('Send drafts to $boxProseName?'), findsOneWidget);
      expect(find.text(CloudDraftsConsentPane.scopeLine), findsOneWidget);
      expect(
        find.text(
          'At most 200 drafts a day go to a third-party target. You can '
          'change the cap under Settings, Processing.',
        ),
        findsOneWidget,
      );
      // Nothing is written by the question itself.
      expect(order, isEmpty);
      // A pane inside the screen and not a popup over it.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Continue records the consent BEFORE it connects',
        (tester) async {
      final order = <String>[];
      await openConsent(tester, order: order);

      await tester.tap(find.byKey(CloudDraftsConsentPane.continueKey));
      await tester.pumpAndSettle();

      // That order is the protection: `setBoxServers` refuses a third-party
      // big address while the flag is false, so a connect made first would
      // throw rather than write.
      expect(order, ['consent', 'connect']);
      // And the pane closed onto the sections it replaced.
      expect(find.byType(CloudDraftsConsentPane), findsNothing);
      expect(find.text('Models'), findsOneWidget);
    });

    testWidgets('a connect that refuses keeps the pane open and says why',
        (tester) async {
      // The form is unmounted by the pane that replaced it, so it has
      // nowhere to draw its own sentence: a pane that closed here would put
      // the person back on an unchanged section with nothing said.
      final order = <String>[];
      await openConsent(
        tester,
        order: order,
        connectThrows: ArgumentError.value(
          _openAiUrl,
          'bigUrl',
          'a third-party server needs cloud drafts consent first',
        ),
      );

      await tester.tap(find.byKey(CloudDraftsConsentPane.continueKey));
      await tester.pumpAndSettle();

      expect(order, ['consent', 'connect']);
      expect(find.byType(CloudDraftsConsentPane), findsOneWidget);
      expect(find.byKey(CloudDraftsConsentPane.errorKey), findsOneWidget);
      expect(
        find.text('a third-party server needs cloud drafts consent first'),
        findsOneWidget,
      );

      // And leaving drops the sentence with the pane.
      await tester.tap(find.byKey(CloudDraftsConsentPane.notNowKey));
      await tester.pumpAndSettle();
      expect(find.byKey(CloudDraftsConsentPane.errorKey), findsNothing);
    });

    testWidgets('a screen that cannot record consent refuses the address '
        'instead of asking', (tester) async {
      final order = <String>[];
      await openConsent(tester, order: order, wireConsent: false);

      // A pane whose Continue wrote no consent would hand the connect
      // straight back to a refusal, so the question is not asked at all.
      expect(find.byType(CloudDraftsConsentPane), findsNothing);
      expect(find.text(ModelServersForm.thirdPartyRefusalText), findsOneWidget);
      expect(order, isEmpty);
    });

    testWidgets('Not now writes nothing at all', (tester) async {
      final order = <String>[];
      await openConsent(tester, order: order);

      await tester.tap(find.byKey(CloudDraftsConsentPane.notNowKey));
      await tester.pumpAndSettle();

      expect(order, isEmpty);
      expect(find.byType(CloudDraftsConsentPane), findsNothing);
    });
  });

  testWidgets('nothing here ever pushes a dialog', (tester) async {
    await open(
      tester,
      section: 'Processing',
      cloudDraftsToday: 3,
      onCloudDraftsDailyCapChanged: (_) {},
    );

    await tester.enterText(find.byKey(SettingsScreen.cloudCapKey), '9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(routes.pushes, 0);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
