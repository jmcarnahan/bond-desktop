import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/providers/app_providers.dart';
import 'package:bond_inbox/screens/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/fake_auth_session.dart';
import 'fixtures/test_db.dart';

/// The sign-in flow, lifted out of its card.
///
/// The wizard hosts the same body inside its own pane, so the one thing the
/// host varies is the title: the pane already carries `Sign in`, and a second
/// `Bond Inbox` under it would be the screen introducing itself twice.
/// Everything else — every string, every button — is the same widget in both
/// places, which is the whole reason it was lifted rather than copied.
void main() {
  late BondDatabase db;

  setUp(() {
    db = testDb();
  });

  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        authSessionProvider.overrideWithValue(FakeAuthSession()),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the screen still introduces itself', (tester) async {
    await pump(tester, SignInScreen(onSignedIn: () {}));

    expect(find.text('Bond Inbox'), findsOneWidget);
    expect(
      find.text('Sign in to your Bond workspace to read your mail.'),
      findsOneWidget,
    );
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('the body without a title is the same screen, minus the name',
      (tester) async {
    await pump(tester, SignInBody(onSignedIn: () {}, showTitle: false));

    expect(find.text('Bond Inbox'), findsNothing);
    // Everything the screen offers is still here.
    expect(
      find.text('Sign in to your Bond workspace to read your mail.'),
      findsOneWidget,
    );
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('the body keeps its title unless a host says otherwise',
      (tester) async {
    await pump(tester, SignInBody(onSignedIn: () {}));

    expect(find.text('Bond Inbox'), findsOneWidget);
  });
}
