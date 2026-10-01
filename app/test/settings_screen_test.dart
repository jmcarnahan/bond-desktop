import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/label_models.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/services/decision/needs_you_predicate.dart';
import 'package:bond_inbox/services/llm/model_slots.dart' show ModelPlacement;
import 'package:bond_inbox/services/server/server_state.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/settings_labels_section.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
import 'package:bond_inbox/widgets/settings_segments.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The settings screen driven directly, with nothing but closures behind it.
///
/// It is a plain widget over props — no provider reads inside — so this file
/// pumps it alone, with no `InboxScreen` and therefore no sixty-second timer,
/// which is what makes `pumpAndSettle` safe here and nowhere near
/// `settings_screen_nav_test.dart`.
void main() {
  Future<void> open(
    WidgetTester tester, {
    double threshold = 0.35,
    String aboutMe = '',
    required void Function(double) onThresholdChanged,
    required void Function(String) onAboutMeChanged,
    Future<bool> Function(String)? hasScope,
    VoidCallback? onSignInAgain,
    bool showActivityLog = false,
    void Function(bool)? onShowActivityLogChanged,
    NotifyStyle notifyStyle = NotifyStyle.native,
    void Function(NotifyStyle)? onNotifyStyleChanged,
    DraftPolicy draftPolicy = DraftPolicy.needsYou,
    void Function(DraftPolicy)? onDraftPolicyChanged,
    SettingsScope scope = SettingsScope.all,
    VoidCallback? onBack,
    VoidCallback? onHome,
    ValueChanged<bool>? onProcessingChanged,
    Future<void> Function()? onClearAiResults,
    List<Label>? labels,
    bool labelsLoading = false,
    String? labelsError,
    Future<bool> Function(String, String)? onRenameLabel,
    void Function(String, String?)? onLabelToneChanged,
    void Function(String)? onDeleteLabel,
    bool replySendMarksDone = false,
    void Function(bool)? onReplySendMarksDoneChanged,
    ({int removed, int added})? needsYouAnswers,
    Future<void> Function()? onForgetNeedsYouAnswers,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          scope: scope,
          threshold: threshold,
          aboutMe: aboutMe,
          onThresholdChanged: onThresholdChanged,
          onAboutMeChanged: onAboutMeChanged,
          onBack: onBack ?? () {},
          onHome: onHome,
          showActivityLog: showActivityLog,
          onShowActivityLogChanged: onShowActivityLogChanged,
          notifyStyle: notifyStyle,
          onNotifyStyleChanged: onNotifyStyleChanged,
          draftPolicy: draftPolicy,
          onDraftPolicyChanged: onDraftPolicyChanged,
          hasScope: hasScope,
          onSignInAgain: onSignInAgain,
          onProcessingChanged: onProcessingChanged,
          onClearAiResults: onClearAiResults,
          labels: labels,
          labelsLoading: labelsLoading,
          labelsError: labelsError,
          onRenameLabel: onRenameLabel,
          onLabelToneChanged: onLabelToneChanged,
          onDeleteLabel: onDeleteLabel,
          replySendMarksDone: replySendMarksDone,
          onReplySendMarksDoneChanged: onReplySendMarksDoneChanged,
          needsYouAnswers: needsYouAnswers,
          onForgetNeedsYouAnswers: onForgetNeedsYouAnswers,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Opens one named section. Everything starts collapsed, so most tests begin
  /// with one of these.
  ///
  /// Scrolled to first: nine sections do not fit a 900pt window once a couple
  /// of them are open, and they certainly do not at a doubled text scale.
  Future<void> expand(WidgetTester tester, String title) async {
    final toggle = find.byKey(SettingsSection.toggleKey(title));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  testWidgets('renders every section collapsed, and the threshold controls '
      'when opened', (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.text('About me'), findsOneWidget);
    expect(find.text('Needs You'), findsOneWidget);
    // Collapsed means the controls are not built at all.
    expect(find.byType(Slider), findsNothing);

    await expand(tester, 'Needs You');

    expect(find.text('How much lands in Needs You'), findsOneWidget);
    expect(find.text('Only the surest'), findsWidgets);
    expect(find.text('Anything plausible'), findsWidgets);
    expect(find.byType(Slider), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(SettingsScreen.needsYouThresholdLineKey))
          .data,
      'Needs you at 35% or more',
    );
    expect(
      find.text("The decision model's confidence that a message needs you. "
          'Each message shows its own percentage.'),
      findsOneWidget,
    );
  });

  group("the owner's Needs You answers", () {
    testWidgets('counts the presses and forgets them in two steps',
        (tester) async {
      var forgot = 0;
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        needsYouAnswers: (removed: 3, added: 1),
        onForgetNeedsYouAnswers: () async => forgot++,
      );
      await expand(tester, 'Needs You');

      expect(find.text('Your answers'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(SettingsScreen.needsYouAnswersLineKey))
            .data,
        "You've removed 3 kinds of mail from Needs You and added 1 kind.",
      );
      final button = find.byKey(SettingsScreen.forgetNeedsYouAnswersKey);
      expect(find.text('Forget all Needs You answers'), findsOneWidget);

      // The first press only arms it.
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(forgot, 0);
      expect(find.text('Really forget?'), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(forgot, 1);
      expect(find.text('Forget all Needs You answers'), findsOneWidget);
    });

    testWidgets('with no answers says so and offers nothing to forget',
        (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        needsYouAnswers: (removed: 0, added: 0),
        onForgetNeedsYouAnswers: () async {},
      );
      await expand(tester, 'Needs You');

      expect(find.text("You haven't answered for any mail yet."),
          findsOneWidget);
      expect(find.byKey(SettingsScreen.forgetNeedsYouAnswersKey),
          findsNothing);
    });

    testWidgets('a Forget that fails says so under the button',
        (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        needsYouAnswers: (removed: 1, added: 0),
        onForgetNeedsYouAnswers: () async => throw StateError('off'),
      );
      await expand(tester, 'Needs You');
      final button = find.byKey(SettingsScreen.forgetNeedsYouAnswersKey);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(
        find.text("Your answers couldn't be forgotten just now — processing "
            'has to be on.'),
        findsOneWidget,
      );
    });

    testWidgets('before the host has read them, no line', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );
      await expand(tester, 'Needs You');

      expect(find.text('Your answers'), findsNothing);
      expect(find.byKey(SettingsScreen.needsYouAnswersLineKey), findsNothing);
    });
  });

  testWidgets('the Needs You summary is the threshold as a percentage',
      (tester) async {
    await open(
      tester,
      threshold: 0.45,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.text('At 45% or more'), findsOneWidget);
    // No rules clause and no queue clause: the slider is the one control.
    expect(find.textContaining('rules'), findsNothing);
    expect(find.textContaining('judging'), findsNothing);
  });

  group('sending a reply marks it done', () {
    testWidgets('is absent when the host cannot write it', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );
      await expand(tester, 'Needs You');

      expect(
        find.byKey(SettingsScreen.replySendMarksDoneKey),
        findsNothing,
      );
      expect(find.text('Sending a reply marks it done'), findsNothing);
    });

    testWidgets('reads off by default, with its words under it',
        (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onReplySendMarksDoneChanged: (_) {},
      );
      await expand(tester, 'Needs You');

      final row = find.byKey(SettingsScreen.replySendMarksDoneKey);
      expect(tester.widget<SwitchListTile>(row).value, isFalse);
      expect(find.text('Sending a reply marks it done'), findsOneWidget);
      expect(
        find.text(
          'A thread leaves Needs You as soon as you answer it, instead of '
          'waiting for you to mark it done.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('flips the moment it is pressed, like every other switch here',
        (tester) async {
      final written = <bool>[];
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onReplySendMarksDoneChanged: written.add,
      );
      await expand(tester, 'Needs You');

      final row = find.byKey(SettingsScreen.replySendMarksDoneKey);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      // The control moved under the finger AND the host heard about it: a
      // preference that only landed on Back could not be checked by the person
      // who flipped it.
      expect(written, [true]);
      expect(tester.widget<SwitchListTile>(row).value, isTrue);
    });

    testWidgets('a stored on reads on', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        replySendMarksDone: true,
        onReplySendMarksDoneChanged: (_) {},
      );
      await expand(tester, 'Needs You');

      final row = find.byKey(SettingsScreen.replySendMarksDoneKey);
      expect(tester.widget<SwitchListTile>(row).value, isTrue);

      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(row).value, isFalse);
    });
  });

  testWidgets('the Needs You section has no text to edit', (tester) async {
    // No language model is asked about needs-you, so there is no prompt.
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('the slider reads right-is-more, so it renders inverted',
      (tester) async {
    // A threshold of 0.8 means "only the surest", towards the LEFT end.
    await open(
      tester,
      threshold: 0.8,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0.05);
    expect(slider.max, 0.95);
    expect(slider.divisions, 18);
    expect(slider.value, closeTo(0.2, 1e-9));
    expect(find.text('Needs you at 80% or more'), findsOneWidget);
  });

  testWidgets('dragging right lowers the threshold, and only on release',
      (tester) async {
    final written = <double>[];
    await open(
      tester,
      threshold: 0.95,
      onThresholdChanged: written.add,
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(written, hasLength(1),
        reason: 'each write reloads the list; one per drag, not one per pixel');
    expect(written.single, lessThan(0.95));
    // Every write is a notch the stored pref can hold, and the line under
    // the slider says the number that was written.
    expect(written.single, NeedsYouTuning.minThreshold);
    expect(find.text('Needs you at 5% or more'), findsOneWidget);
  });

  testWidgets('a drag to the middle writes the notch it landed on',
      (tester) async {
    final written = <double>[];
    await open(
      tester,
      threshold: 0.95,
      onThresholdChanged: written.add,
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    // From the left end to the centre of the track: position 0.5, the
    // threshold 0.95 + 0.05 − 0.5.
    final slider = find.byType(Slider);
    final box = tester.getRect(slider);
    await tester.dragFrom(
      Offset(box.left + 24, box.center.dy),
      Offset(box.width / 2 - 24, 0),
    );
    await tester.pumpAndSettle();

    expect(written, hasLength(1));
    expect(written.single, isIn(const [0.45, 0.5, 0.55]));
    expect(
      find.text('Needs you at ${(written.single * 100).round()}% or more'),
      findsOneWidget,
    );
  });

  testWidgets('Save commits the text', (tester) async {
    final saved = <String>[];
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: saved.add,
    );
    await expand(tester, 'About me');

    await tester.enterText(
      find.byType(TextField),
      'I own the website redesign.',
    );
    await tester.pump();
    expect(saved, isEmpty, reason: 'not saved per keystroke');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, ['I own the website redesign.']);
  });

  testWidgets('Cancel reverts the field to the last saved text',
      (tester) async {
    final saved = <String>[];
    await open(
      tester,
      aboutMe: 'the original',
      onThresholdChanged: (_) {},
      onAboutMeChanged: saved.add,
    );
    await expand(tester, 'About me');

    await tester.enterText(find.byType(TextField), 'typed then cancelled');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'the original',
    );
    expect(saved, isEmpty);
  });

  testWidgets('nothing is saved on dispose', (tester) async {
    // Not just an economy: a sign-in from this screen that changes the
    // identity wipes the previous person's about-me, and a save on the way out
    // would write it right back. Save is the whole contract now.
    final saved = <String>[];
    await open(
      tester,
      aboutMe: 'the previous text',
      onThresholdChanged: (_) {},
      onAboutMeChanged: saved.add,
    );
    await expand(tester, 'About me');

    await tester.enterText(find.byType(TextField), 'typed and abandoned');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
  });

  testWidgets('a clean about-me adopts a value changed underneath it',
      (tester) async {
    // A sign-in from inside Settings that changes the identity wipes the
    // previous person's about-me to '' under an open screen. A field nobody
    // has touched must follow, or the old text sits there looking saved.
    await open(
      tester,
      aboutMe: 'the previous person',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'About me');

    // The same tree pumped again with a new prop is the host rebuilding.
    await open(
      tester,
      aboutMe: '',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.text('Not written yet'), findsOneWidget);
  });

  testWidgets('a dirty about-me keeps its edit when the value changes '
      'underneath it', (tester) async {
    // An unsaved edit is the user's, whatever the host now says.
    await open(
      tester,
      aboutMe: 'the previous person',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'About me');
    await tester.enterText(find.byType(TextField), 'my own words');
    await tester.pump();

    await open(
      tester,
      aboutMe: '',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'my own words',
    );
  });

  testWidgets('it opens on what is already stored', (tester) async {
    await open(
      tester,
      aboutMe: 'stored text',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'About me');

    // Scoped to the field: a short about-me is also its own summary, one line
    // above, so a bare text finder would match twice.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'stored text',
    );
  });

  testWidgets('the collapsed summary shows the stored text', (tester) async {
    // Long enough to be cut, and folded onto one line: the summary is a
    // one-line answer, not a preview of the paragraph.
    const long =
        'I run marketing at a small company.\nI own the website redesign, the '
        'event calendar, and the newsletter nobody reads.';
    await open(
      tester,
      aboutMe: long,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    final oneLine = long.replaceAll(RegExp(r'\s+'), ' ');
    expect(find.text('${oneLine.substring(0, 80)}…'), findsOneWidget);
  });

  testWidgets('an empty about-me says so rather than showing nothing',
      (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.text('Not written yet'), findsOneWidget);
  });

  testWidgets('what the screen writes lands in app_prefs', (tester) async {
    final db = testDb();
    addTearDown(db.close);
    final store = MessageStore(db);

    final container = ProviderContainer(
      overrides: [dbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final prefs = container.read(appPrefsProvider.notifier);

    await open(
      tester,
      threshold: container.read(appPrefsProvider).needsYouThreshold,
      aboutMe: container.read(appPrefsProvider).aboutMe,
      onThresholdChanged: prefs.setNeedsYouThreshold,
      onAboutMeChanged: prefs.setAboutMe,
    );

    await expand(tester, 'About me');
    await tester.enterText(
      find.byType(TextField),
      'I run a small design studio.',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await expand(tester, 'Needs You');
    await tester.drag(find.byType(Slider), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(await store.getPref(aboutMeKey), 'I run a small design studio.');
    // The slider's far end, clamped to the Needs You range by the writer.
    expect(
      double.parse((await store.getPref(needsYouThresholdKey))!),
      NeedsYouTuning.maxThreshold,
    );
    expect(
      container.read(appPrefsProvider).needsYouThreshold,
      NeedsYouTuning.maxThreshold,
    );
  });

  testWidgets('the home link is absent unless the host wires one',
      (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.byTooltip('Inbox'), findsNothing);

    var home = 0;
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
      onHome: () => home++,
    );

    expect(find.byTooltip('Inbox'), findsOneWidget);
    await tester.tap(find.byTooltip('Inbox'));
    await tester.pumpAndSettle();
    expect(home, 1);
  });

  testWidgets("Back fires the host's callback", (tester) async {
    var backs = 0;
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
      onBack: () => backs++,
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(backs, 1);
  });

  testWidgets('two sections can be open at once', (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
      onNotifyStyleChanged: (_) {},
    );

    await expand(tester, 'About me');
    await expand(tester, 'Notifications');

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(SegmentedButton<NotifyStyle>), findsOneWidget);
    // Both toggles say Collapse, so neither closed the other.
    expect(find.text('Collapse'), findsNWidgets(2));
  });

  testWidgets('every section survives a doubled text scale', (tester) async {
    // The three places that overflow first: the section header row, the pane
    // header with the Home button, and the threshold's two end labels.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(
      tester,
      aboutMe: 'a paragraph about the person using this',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
      onShowActivityLogChanged: (_) {},
      onNotifyStyleChanged: (_) {},
      hasScope: (_) async => true,
      onSignInAgain: () {},
      onHome: () {},
      onProcessingChanged: (_) {},
      onClearAiResults: () async {},
    );

    // In render order, which is where Processing sits: after the log and
    // before Sync & data, neither of which is wired here.
    for (final title in const [
      'About me',
      'Microsoft connection',
      'Needs You',
      'Notifications',
      'Activity log',
      'Processing',
    ]) {
      await expand(tester, title);
    }

    expect(tester.takeException(), isNull);
  });

  group('the activity log switch', () {
    testWidgets('is absent when the host wires no callback', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );

      expect(find.text('Activity log'), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
    });

    testWidgets('renders on what is already stored', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        showActivityLog: true,
        onShowActivityLogChanged: (_) {},
      );
      expect(find.text('Shown in the sidebar'), findsOneWidget);

      await expand(tester, 'Activity log');

      expect(find.text('Show activity log'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
    });

    testWidgets('reports the flip immediately, not on the way out',
        (tester) async {
      // The icon this switch controls is on the rail behind this pane. A
      // toggle whose effect only lands on Back cannot be checked by the person
      // who just flipped it.
      final written = <bool>[];
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onShowActivityLogChanged: written.add,
      );
      await expand(tester, 'Activity log');

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(written, [true]);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(written, [true, false]);
    });
  });

  group('the notification style row', () {
    testWidgets('is absent when the host wires no callback', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );

      expect(find.text('Notifications'), findsNothing);
    });

    testWidgets('renders on what is already stored', (tester) async {
      // Off, which is the only one of the three that took a decision to reach:
      // this preference defaults to native.
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        notifyStyle: NotifyStyle.off,
        onNotifyStyleChanged: (_) {},
      );

      expect(find.text('Notifications'), findsOneWidget);

      await expand(tester, 'Notifications');

      expect(find.text('Off'), findsWidgets);
      expect(find.text('In-app'), findsOneWidget);
      expect(find.text('Native'), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<NotifyStyle>>(
              find.byType(SegmentedButton<NotifyStyle>),
            )
            .selected,
        {NotifyStyle.off},
      );
      // The one thing about native a user would otherwise report as a bug.
      expect(
        find.textContaining('falls back to the in-app ribbon'),
        findsOneWidget,
      );
    });

    testWidgets('reports the choice immediately', (tester) async {
      final written = <NotifyStyle>[];
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onNotifyStyleChanged: written.add,
      );
      await expand(tester, 'Notifications');

      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();

      expect(written, [NotifyStyle.off]);
      expect(
        tester
            .widget<SegmentedButton<NotifyStyle>>(
              find.byType(SegmentedButton<NotifyStyle>),
            )
            .selected,
        {NotifyStyle.off},
      );

      await tester.tap(find.text('In-app'));
      await tester.pumpAndSettle();

      expect(written, [NotifyStyle.off, NotifyStyle.inApp]);
    });

    testWidgets('sits beside the activity log switch, not instead of it',
        (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onShowActivityLogChanged: (_) {},
        onNotifyStyleChanged: (_) {},
      );

      // Two sections, in the one scrolling pane. That there is no popup
      // anywhere in lib/ is `no_dialogs_test.dart`'s job to pin.
      expect(find.text('Activity log'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);

      await expand(tester, 'Activity log');
      await expand(tester, 'Notifications');

      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.text('Show activity log'), findsOneWidget);
      expect(find.byType(SegmentedButton<NotifyStyle>), findsOneWidget);
    });
  });

  group('Suggested replies', () {
    testWidgets('is absent when the host wires no callback', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );

      expect(find.text('Suggested replies'), findsNothing);
    });

    // One test per mode rather than a loop inside one: each case is a fresh
    // screen reading a different stored value, which is what the summary line
    // is about. A second pumpWidget into the same tree reuses the first State
    // and follows the new prop, which is the resync case below.
    for (final (policy, summary) in const [
      (DraftPolicy.needsYou, 'For messages that need you'),
      (DraftPolicy.all, 'For every reply-worthy message'),
      (DraftPolicy.onDemand, 'Only when asked'),
    ]) {
      testWidgets('its summary for $policy says what the mode does, '
          'not its name', (tester) async {
        await open(
          tester,
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          draftPolicy: policy,
          onDraftPolicyChanged: (_) {},
        );

        expect(find.text('Suggested replies'), findsOneWidget);
        expect(find.text(summary), findsOneWidget);
      });
    }

    testWidgets('renders the three segments on what is already stored',
        (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        draftPolicy: DraftPolicy.onDemand,
        onDraftPolicyChanged: (_) {},
      );
      await expand(tester, 'Suggested replies');

      expect(find.text('Needs you'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('When asked'), findsWidgets);
      expect(
        tester
            .widget<SegmentedButton<DraftPolicy>>(
              find.byType(SegmentedButton<DraftPolicy>),
            )
            .selected,
        {DraftPolicy.onDemand},
      );
      // The sentence that keeps "When asked" from reading as "off".
      expect(
        find.textContaining('which works in every mode'),
        findsOneWidget,
      );
    });

    testWidgets('reports the choice immediately', (tester) async {
      final written = <DraftPolicy>[];
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onDraftPolicyChanged: written.add,
      );
      await expand(tester, 'Suggested replies');

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      expect(written, [DraftPolicy.all]);
      expect(
        tester
            .widget<SegmentedButton<DraftPolicy>>(
              find.byType(SegmentedButton<DraftPolicy>),
            )
            .selected,
        {DraftPolicy.all},
      );

      await tester.tap(find.text('When asked'));
      await tester.pumpAndSettle();

      expect(written, [DraftPolicy.all, DraftPolicy.onDemand]);
    });

    testWidgets('follows the prop when the host changes the policy underneath',
        (tester) async {
      // A tier's defaults rewrite the draft policy without anyone touching
      // this control. The segments are seeded from the prop once, so without
      // the resync in `didUpdateWidget` they would keep showing the old mode.
      final written = <DraftPolicy>[];
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        draftPolicy: DraftPolicy.needsYou,
        onDraftPolicyChanged: written.add,
      );
      await expand(tester, 'Suggested replies');

      expect(
        tester
            .widget<SegmentedButton<DraftPolicy>>(
              find.byType(SegmentedButton<DraftPolicy>),
            )
            .selected,
        {DraftPolicy.needsYou},
      );

      // The same tree, the same State, one prop changed.
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        draftPolicy: DraftPolicy.onDemand,
        onDraftPolicyChanged: written.add,
      );

      expect(
        tester
            .widget<SegmentedButton<DraftPolicy>>(
              find.byType(SegmentedButton<DraftPolicy>),
            )
            .selected,
        {DraftPolicy.onDemand},
      );
      expect(find.text('Only when asked'), findsOneWidget);
      // Adopting what the host already decided is not a new decision, so
      // nothing is reported back.
      expect(written, isEmpty);
    });

    // No `!ai` guard, deliberately: how much of the big model's time goes on
    // replies nobody asked for is a fact about the model, so the AI stop is
    // where someone would look for it.
    for (final scope in SettingsScope.values) {
      testWidgets('is present under $scope', (tester) async {
        await open(
          tester,
          scope: scope,
          onThresholdChanged: (_) {},
          onAboutMeChanged: (_) {},
          onDraftPolicyChanged: (_) {},
          onNotifyStyleChanged: (_) {},
        );

        expect(find.text('Suggested replies'), findsOneWidget);
      });
    }

    testWidgets('sits between Needs You and Notifications', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        onDraftPolicyChanged: (_) {},
        onNotifyStyleChanged: (_) {},
      );

      double topOf(String title) =>
          tester.getTopLeft(find.text(title).first).dy;

      expect(topOf('Needs You'), lessThan(topOf('Suggested replies')));
      expect(topOf('Suggested replies'), lessThan(topOf('Notifications')));
    });
  });

  group('Microsoft permissions', () {
    testWidgets('the section is absent when no auth is wired', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );

      expect(find.text('Microsoft connection'), findsNothing);
      expect(find.text('Microsoft permissions'), findsNothing);
    });

    testWidgets('a full grant ticks all four and offers no sign-in',
        (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        hasScope: (_) async => true,
        onSignInAgain: () {},
      );
      await expand(tester, 'Microsoft connection');

      expect(find.text('Send mail'), findsOneWidget);
      expect(find.text('Save drafts'), findsOneWidget);
      expect(find.text('Teams chats'), findsOneWidget);
      expect(find.text('Calendar (read and write)'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNWidgets(4));
      expect(find.byIcon(Icons.close), findsNothing);
      // A tenant that granted everything has nothing to be nagged about.
      expect(find.text('Sign in again to enable'), findsNothing);
    });

    testWidgets('a degraded grant crosses what is missing and offers a re-sign',
        (tester) async {
      final asked = <String>[];
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        hasScope: (scope) async {
          asked.add(scope);
          return scope == 'mail.readwrite';
        },
        onSignInAgain: () {},
      );
      await expand(tester, 'Microsoft connection');

      expect(asked, [
        'mail.send',
        'mail.readwrite',
        'chat.read',
        'calendars.readwrite',
      ]);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNWidgets(3));
      expect(find.text('Sign in again to enable'), findsOneWidget);
    });

    testWidgets('a missing admin-gated scope alone offers no sign-in',
        (tester) async {
      // Chat.Read is not in the requested set (tenant admin-gates it), so a
      // fresh sign-in cannot deliver it — offering one would be a permanent
      // nag pointing at a round that cannot succeed.
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        hasScope: (scope) async => scope != 'chat.read',
        onSignInAgain: () {},
      );
      await expand(tester, 'Microsoft connection');

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('Sign in again to enable'), findsNothing);
    });

    testWidgets('a missing calendar grant alone offers no sign-in',
        (tester) async {
      // Calendars.ReadWrite arrives through the platform-side reconnect, the
      // same as the Teams grant, so this app's sign-in cannot deliver it.
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        hasScope: (scope) async => scope != 'calendars.readwrite',
        onSignInAgain: () {},
      );
      await expand(tester, 'Microsoft connection');

      expect(find.text('Calendar (read and write)'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('Sign in again to enable'), findsNothing);
    });

    testWidgets('the sign-in offer fires its callback', (tester) async {
      var asked = 0;
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        hasScope: (_) async => false,
        onSignInAgain: () => asked++,
      );
      await expand(tester, 'Microsoft connection');

      await tester.tap(find.text('Sign in again to enable'));
      await tester.pumpAndSettle();

      expect(asked, 1);
    });

    testWidgets('the keychain is read once, not once per rebuild',
        (tester) async {
      // A FutureBuilder handed a future built inside build re-runs the whole
      // read on every rebuild — including the ones the slider causes.
      var reads = 0;
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        hasScope: (_) async {
          reads++;
          return true;
        },
        onSignInAgain: () {},
      );
      await expand(tester, 'Microsoft connection');
      await expand(tester, 'Needs You');
      await tester.drag(find.byType(Slider), const Offset(-100, 0));
      await tester.pumpAndSettle();

      expect(reads, 4, reason: 'four scopes, asked once each');
    });
  });

  /// The Models section's own collapsed line. It says where each ROLE runs
  /// and then the app's own server's state.
  group('the Models summary', () {
    Future<void> openModels(
      WidgetTester tester, {
      ModelPlacement decision = ModelPlacement.local,
      ModelPlacement generative = ModelPlacement.local,
      ServerState serverState = const ServerStopped(),
      String generativeUrl = '',
      bool wireModels = true,
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> write({
        required ModelPlacement placement,
        String? managedModel,
        String? url,
        String? model,
        String? key,
        bool clearKey = false,
      }) async {}
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            threshold: 0.5,
            aboutMe: '',
            onThresholdChanged: (_) {},
            onAboutMeChanged: (_) {},
            onBack: () {},
            decisionPlacement: decision,
            generativePlacement: generative,
            serverState: serverState,
            generativeUrl: generativeUrl,
            onUseDecision: wireModels ? write : null,
            onUseGenerative: wireModels ? write : null,
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('both roles on this Mac carry the server’s own state',
        (tester) async {
      await openModels(
        tester,
        serverState: const ServerReady(port: 8080, pid: 42),
      );

      expect(find.text('Models'), findsOneWidget);
      expect(
        find.text('Decision on this Mac · Generative on this Mac · Running'),
        findsOneWidget,
      );
    });

    testWidgets('a role on your server names the host the work goes to',
        (tester) async {
      await openModels(
        tester,
        generative: ModelPlacement.box,
        generativeUrl: 'https://box.example.com/prose/v1/chat/completions',
      );

      expect(
        find.text(
          'Decision on this Mac · Generative at box.example.com · Not running',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a host that cannot connect anywhere has no section at all',
        (tester) async {
      await openModels(tester, wireModels: false);

      expect(find.text('Models'), findsNothing);
    });
  });

  /// The owner's vocabulary: the one place a label can be renamed, recoloured or
  /// thrown away. Seam-driven like every other section here, so these tests
  /// drive the whole thing with a list and three closures.
  group('the Labels section', () {
    Label label(
      String id,
      String name, {
      String? tone,
      int uses = 0,
    }) =>
        Label(id: id, name: name, tone: tone, useCount: uses);

    List<Label> vocabulary() => [
          label('legal', 'Waiting on legal', tone: 'attention', uses: 9),
          label('jira', 'Jira update', uses: 3),
        ];

    Future<void> openLabels(
      WidgetTester tester, {
      List<Label>? labels,
      bool loading = false,
      String? error,
      Future<bool> Function(String, String)? onRename,
      void Function(String, String?)? onTone,
      void Function(String)? onDelete,
      bool opened = true,
    }) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
        labels: labels,
        labelsLoading: loading,
        labelsError: error,
        onRenameLabel: onRename,
        onLabelToneChanged: onTone,
        onDeleteLabel: onDelete,
      );
      if (opened && labels != null) {
        final toggle = find.byKey(SettingsSection.toggleKey('Labels'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
      }
    }

    testWidgets('a host that has not wired the vocabulary has no section',
        (tester) async {
      // Absent wiring, absent section — the discipline every optional section
      // on this screen follows.
      await openLabels(tester);

      expect(find.text('Labels'), findsNothing);
    });

    testWidgets('the section title and its collapsed line', (tester) async {
      await openLabels(tester, labels: vocabulary(), opened: false);

      // Pinned here, in `docs/settings.md` and in the screen itself — the three
      // move together.
      expect(find.text('Labels'), findsOneWidget);
      expect(find.text('2 labels · 12 uses'), findsOneWidget);
      // Collapsed means the rows are not built at all.
      expect(find.text('Jira update'), findsNothing);
    });

    test('the collapsed line counts words, then uses', () {
      expect(LabelsSection.summaryOf(const []), 'No labels yet');
      expect(
        LabelsSection.summaryOf([label('a', 'Alpha')]),
        '1 label',
      );
      expect(
        LabelsSection.summaryOf([label('a', 'Alpha', uses: 1)]),
        '1 label · 1 use',
      );
      expect(LabelsSection.summaryOf(vocabulary()), '2 labels · 12 uses');
    });

    testWidgets('each word is a row, with what it is and how used it is',
        (tester) async {
      await openLabels(tester, labels: vocabulary());

      expect(find.byKey(LabelsSection.rowKeyFor('legal')), findsOneWidget);
      expect(find.text('Waiting on legal'), findsOneWidget);
      expect(find.text('Used 9 times'), findsOneWidget);
      expect(find.text('Used 3 times'), findsOneWidget);
    });

    testWidgets('and a word nobody has reached for yet says so', (tester) async {
      await openLabels(tester, labels: [label('new', 'Later')]);

      expect(find.text('Not used yet'), findsOneWidget);
    });

    testWidgets('an empty vocabulary says where labels come from',
        (tester) async {
      await openLabels(tester, labels: const []);

      expect(find.textContaining('mark it done with a label'), findsOneWidget);
    });

    testWidgets('renaming keeps the label and closes the field', (tester) async {
      final renames = <(String, String)>[];
      await openLabels(
        tester,
        labels: vocabulary(),
        onRename: (id, name) async {
          renames.add((id, name));
          return true;
        },
      );

      await tester.tap(find.byKey(LabelsSection.renameKeyFor('jira')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(LabelsSection.nameFieldKeyFor('jira')),
        'Jira tickets',
      );
      await tester.tap(find.byKey(LabelsSection.saveKeyFor('jira')));
      await tester.pumpAndSettle();

      expect(renames, [('jira', 'Jira tickets')]);
      // The host owns the list, so the row still reads the old name until the
      // provider hands a new one down — but the field is done with.
      expect(find.byKey(LabelsSection.nameFieldKeyFor('jira')), findsNothing);
    });

    testWidgets('a name already taken is refused under the field, not in a '
        'dialog', (tester) async {
      await openLabels(
        tester,
        labels: vocabulary(),
        error: 'A label called “Waiting on legal” already exists.',
        onRename: (_, _) async => false,
      );

      await tester.tap(find.byKey(LabelsSection.renameKeyFor('jira')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(LabelsSection.nameFieldKeyFor('jira')),
        'Waiting on legal',
      );
      await tester.tap(find.byKey(LabelsSection.saveKeyFor('jira')));
      await tester.pumpAndSettle();

      // Open, on what was typed, with the reason under it: retyping a name to
      // find out it is still taken is the one thing an inline refusal avoids.
      expect(find.byKey(LabelsSection.nameFieldKeyFor('jira')), findsOneWidget);
      expect(
        find.text('A label called “Waiting on legal” already exists.'),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('Cancel drops the typed name and leaves the label alone',
        (tester) async {
      var renames = 0;
      await openLabels(
        tester,
        labels: vocabulary(),
        onRename: (_, _) async {
          renames++;
          return true;
        },
      );

      await tester.tap(find.byKey(LabelsSection.renameKeyFor('jira')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(LabelsSection.nameFieldKeyFor('jira')),
        'Something else',
      );
      await tester.tap(find.byKey(LabelsSection.cancelKeyFor('jira')));
      await tester.pumpAndSettle();

      expect(renames, 0);
      expect(find.byKey(LabelsSection.nameFieldKeyFor('jira')), findsNothing);
    });

    testWidgets('the tint is picked while renaming, and reported at once',
        (tester) async {
      final tones = <(String, String?)>[];
      await openLabels(
        tester,
        labels: vocabulary(),
        onRename: (_, _) async => true,
        onTone: (id, tone) => tones.add((id, tone)),
      );

      // The swatch beside the name is what a reader needs the rest of the time;
      // five segments per row would be five rows of buttons.
      expect(find.byType(SettingsSegments<BondTone>), findsNothing);

      await tester.tap(find.byKey(LabelsSection.renameKeyFor('jira')));
      await tester.pumpAndSettle();

      expect(find.byKey(LabelsSection.toneKeyFor('jira')), findsOneWidget);

      await tester.tap(find.text('Moss'));
      await tester.pumpAndSettle();

      expect(tones, [('jira', 'success')]);
    });

    testWidgets('and choosing Stone clears the stored word', (tester) async {
      final tones = <(String, String?)>[];
      await openLabels(
        tester,
        labels: vocabulary(),
        onRename: (_, _) async => true,
        onTone: (id, tone) => tones.add((id, tone)),
      );

      await tester.tap(find.byKey(LabelsSection.renameKeyFor('legal')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stone'));
      await tester.pumpAndSettle();

      // A label with no tone and a label set back to plain must not be two
      // different rows in the table.
      expect(tones, [('legal', null)]);
    });

    testWidgets('Remove asks a second time, on a different button',
        (tester) async {
      final deleted = <String>[];
      await openLabels(
        tester,
        labels: vocabulary(),
        onDelete: deleted.add,
      );

      await tester.tap(find.byKey(LabelsSection.removeKeyFor('jira')));
      await tester.pumpAndSettle();

      expect(deleted, isEmpty);
      // The protection is that the second press lands on a DIFFERENT button
      // that did not exist a moment ago, and the caption says what goes.
      expect(
        find.textContaining('takes it off every thread it is on'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(LabelsSection.confirmRemoveKeyFor('jira')));
      await tester.pumpAndSettle();

      expect(deleted, ['jira']);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('and Keep disarms it', (tester) async {
      final deleted = <String>[];
      await openLabels(
        tester,
        labels: vocabulary(),
        onDelete: deleted.add,
      );

      await tester.tap(find.byKey(LabelsSection.removeKeyFor('jira')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LabelsSection.keepKeyFor('jira')));
      await tester.pumpAndSettle();

      expect(deleted, isEmpty);
      expect(
        find.byKey(LabelsSection.confirmRemoveKeyFor('jira')),
        findsNothing,
      );
    });

    testWidgets('a host with no mutators wired draws the words and no controls',
        (tester) async {
      await openLabels(tester, labels: vocabulary());

      expect(find.text('Jira update'), findsOneWidget);
      expect(find.byKey(LabelsSection.renameKeyFor('jira')), findsNothing);
      expect(find.byKey(LabelsSection.removeKeyFor('jira')), findsNothing);
    });

    testWidgets('a failed read is said at the top of the section',
        (tester) async {
      await openLabels(
        tester,
        labels: vocabulary(),
        error: 'Could not read your labels.',
      );

      expect(find.text('Could not read your labels.'), findsOneWidget);
    });

  });
}
