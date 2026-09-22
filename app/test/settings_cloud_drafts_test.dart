import 'package:bond_inbox/screens/consent_screen.dart'
    show CloudDraftsConsentPane;
import 'package:bond_inbox/services/llm/model_slots.dart';
import 'package:bond_inbox/widgets/settings_models_body.dart';
import 'package:bond_inbox/widgets/settings_models_simple.dart';
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

const _bedrock = LlmTargetSpec(
  id: 't-99887766',
  name: 'Bedrock Opus',
  url: 'https://bedrock-runtime.example.com/',
  model: 'us.example.opus',
  wire: LlmWire.bedrockConverse,
);

const _fast = LlmTargetSpec(
  id: builtInFastId,
  name: builtInFastName,
  url: 'http://localhost:8082/v1/chat/completions',
  model: 'qwen3-4b',
);

const _prose = LlmTargetSpec(
  id: builtInProseId,
  name: builtInProseName,
  url: 'http://localhost:8080/v1/chat/completions',
  model: 'qwen3-27b',
);

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
          // Wired only for the consent case: the Models section needs a slot
          // editor behind it before it will render at all.
          onSlotTargetChanged:
              models ? (_, {required url, required model}) {} : null,
          targets: models ? const [_fast, _prose, _bedrock] : const [],
          onStageTargetChanged: models ? (_, _) {} : null,
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
        find.text('Pick a target for Improve a draft under Models first.'),
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
    testWidgets('quotes the cap in force, not a hardcoded fifty',
        (tester) async {
      await open(
        tester,
        section: 'Models',
        models: true,
        cloudDraftsDailyCap: 200,
      );

      // The stage table is one fold down since Round H: the Models section
      // opens on the simple page, and the pickers are its Advanced content.
      final advanced = find.byKey(
        SettingsSection.toggleKey(SettingsModelsSimple.advancedTitle),
      );
      await tester.ensureVisible(advanced);
      await tester.pumpAndSettle();
      await tester.tap(advanced);
      await tester.pumpAndSettle();

      // A third-party target on a draft stage is the one pick that asks first.
      final picker =
          find.byKey(SettingsModelsBody.stagePickerKey('draft_reply'));
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bedrock Opus').last);
      await tester.pumpAndSettle();

      expect(find.byType(CloudDraftsConsentPane), findsOneWidget);
      expect(
        find.text(
          'At most 200 drafts a day go to a third-party target. You can '
          'change the cap under Settings, Processing.',
        ),
        findsOneWidget,
      );
      // A pane inside the screen and not a popup over it. The route count is
      // not the check here — a dropdown's own menu is a route — so the claim
      // is the one the house rule actually makes.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
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
