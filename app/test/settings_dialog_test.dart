import 'package:bond_inbox/data/db.dart';
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/providers/prefs_provider.dart';
import 'package:bond_inbox/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  /// Opens the dialog over a host that can pop it, which is what the "saved on
  /// close" path needs.
  Future<void> open(
    WidgetTester tester, {
    double threshold = 0.5,
    String aboutMe = '',
    required void Function(double) onThresholdChanged,
    required void Function(String) onAboutMeChanged,
    Future<bool> Function(String)? hasScope,
    VoidCallback? onSignInAgain,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SettingsDialog(
                threshold: threshold,
                aboutMe: aboutMe,
                onThresholdChanged: onThresholdChanged,
                onAboutMeChanged: onAboutMeChanged,
                hasScope: hasScope,
                onSignInAgain: onSignInAgain,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders both controls and both end labels', (tester) async {
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.text('How much lands in Needs You'), findsOneWidget);
    expect(find.text('Only the critical'), findsOneWidget);
    expect(find.text('Anything plausible'), findsOneWidget);
    expect(find.text('About me & my role'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
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

    await tester.drag(find.byType(Slider), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(written, hasLength(1),
        reason: 'each write reloads the list; one per drag, not one per pixel');
    expect(written.single, lessThan(1));
  });

  testWidgets('the about-me text is saved when the dialog closes',
      (tester) async {
    final saved = <String>[];
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: saved.add,
    );

    await tester.enterText(find.byType(TextField), 'I own rate locks.');
    expect(saved, isEmpty, reason: 'not saved per keystroke');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(saved, ['I own rate locks.']);
  });

  testWidgets('and saved when it is dismissed rather than confirmed',
      (tester) async {
    // Most people click outside. Wiring the save to the button alone would
    // quietly lose their text.
    final saved = <String>[];
    await open(
      tester,
      onThresholdChanged: (_) {},
      onAboutMeChanged: saved.add,
    );

    await tester.enterText(find.byType(TextField), 'typed then dismissed');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(saved, ['typed then dismissed']);
  });

  testWidgets('it opens on what is already stored', (tester) async {
    await open(
      tester,
      aboutMe: 'stored text',
      onThresholdChanged: (_) {},
      onAboutMeChanged: (_) {},
    );

    expect(find.text('stored text'), findsOneWidget);
  });

  testWidgets('what the dialog writes lands in app_prefs', (tester) async {
    final db = sqlite3.openInMemory();
    applySchema(db);
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

    await tester.enterText(find.byType(TextField), 'I am a loan officer.');
    await tester.drag(find.byType(Slider), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(store.getPref(aboutMeKey), 'I am a loan officer.');
    expect(double.parse(store.getPref(attentionThresholdKey)!), 1.0);
    expect(container.read(appPrefsProvider).attentionThreshold, 1.0);
  });

  group('Microsoft permissions', () {
    testWidgets('the section is absent when no auth is wired', (tester) async {
      await open(
        tester,
        onThresholdChanged: (_) {},
        onAboutMeChanged: (_) {},
      );

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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();

      expect(asked, ['mail.send', 'mail.readwrite', 'chat.read']);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNWidgets(2));
      expect(find.text('Sign in again to enable'), findsOneWidget);
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
      await tester.pumpAndSettle();

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
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider), const Offset(-100, 0));
      await tester.pumpAndSettle();

      expect(reads, 3, reason: 'three scopes, asked once each');
    });
  });
}
