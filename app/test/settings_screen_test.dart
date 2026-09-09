import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/widgets/settings_screen.dart';
import 'package:bond_inbox/widgets/settings_section.dart';
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
    double threshold = 0.5,
    String aboutMe = '',
    required void Function(double) onThresholdChanged,
    required void Function(String) onAboutMeChanged,
    Future<bool> Function(String)? hasScope,
    VoidCallback? onSignInAgain,
    bool showActivityLog = false,
    void Function(bool)? onShowActivityLogChanged,
    NotifyStyle notifyStyle = NotifyStyle.native,
    void Function(NotifyStyle)? onNotifyStyleChanged,
    VoidCallback? onBack,
    VoidCallback? onHome,
    int needsYouRejudging = 0,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
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
          hasScope: hasScope,
          onSignInAgain: onSignInAgain,
          needsYouRejudging: needsYouRejudging,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Opens one named section. Everything starts collapsed, so most tests begin
  /// with one of these.
  ///
  /// Scrolled to first: eight sections do not fit a 900pt window once a couple
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
    expect(find.text('Only the critical'), findsWidgets);
    expect(find.text('Anything plausible'), findsWidgets);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('the Needs You summary says how much is being re-judged',
      (tester) async {
    // The only feedback a rules save gives: the verdicts themselves move
    // minutes later, on a queue this screen does not show.
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
      needsYouRejudging: 3,
    );

    expect(find.textContaining('judging 3 messages'), findsOneWidget);
  });

  testWidgets('and says it in the singular for one', (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
      needsYouRejudging: 1,
    );

    expect(find.textContaining('judging 1 message'), findsOneWidget);
  });

  testWidgets('and says nothing at all when the queue is empty',
      (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.textContaining('judging'), findsNothing);
  });

  testWidgets('the rules editor is absent when no save is wired',
      (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('the slider reads right-is-more, so it renders inverted',
      (tester) async {
    // A threshold of 0.8 means "only the critical", which is the LEFT end.
    await open(
      tester,
      threshold: 0.8,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    expect(tester.widget<Slider>(find.byType(Slider)).value, closeTo(0.2, 1e-9));
  });

  testWidgets('dragging right lowers the threshold, and only on release',
      (tester) async {
    final written = <double>[];
    await open(
      tester,
      threshold: 1,
      onThresholdChanged: written.add,
      onAboutMeChanged: (_) {},
    );
    await expand(tester, 'Needs You');

    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(written, hasLength(1),
        reason: 'each write reloads the list; one per drag, not one per pixel');
    expect(written.single, lessThan(1));
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
      threshold: container.read(appPrefsProvider).attentionThreshold,
      aboutMe: container.read(appPrefsProvider).aboutMe,
      onThresholdChanged: prefs.setAttentionThreshold,
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
    expect(double.parse((await store.getPref(attentionThresholdKey))!), 1.0);
    expect(container.read(appPrefsProvider).attentionThreshold, 1.0);
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
    );

    for (final title in const [
      'About me',
      'Microsoft connection',
      'Needs You',
      'Notifications',
      'Activity log',
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

    testWidgets('a full grant ticks all three and offers no sign-in',
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
      expect(find.byIcon(Icons.check), findsNWidgets(3));
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

      expect(asked, ['mail.send', 'mail.readwrite', 'chat.read']);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNWidgets(2));
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

      expect(reads, 3, reason: 'three scopes, asked once each');
    });
  });
}
