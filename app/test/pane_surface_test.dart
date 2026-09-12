import 'package:bond_inbox/widgets/pane_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chrome every full-pane screen wears, so the pane reads as the main pane
/// changing rather than as an overlay.
///
/// What is pinned here is the way out. Back is always there; Home is there only
/// when the host has a Home to offer, because a pane that promised a
/// destination the host cannot reach would be a dead button. And the title
/// yields before either of them does — it is the one thing on the row that can
/// afford to be shortened.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String title = 'Settings',
    VoidCallback? onBack,
    VoidCallback? onHome,
    Widget? trailing,
    Size surface = const Size(900, 600),
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PaneSurface(
          title: title,
          onBack: onBack,
          onHome: onHome,
          trailing: trailing,
          child: const Text('the pane body'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders the title, a back arrow, and the body', (tester) async {
    await pump(tester, title: 'Settings', onBack: () {});

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('the pane body'), findsOneWidget);
  });

  testWidgets('Back fires the host callback', (tester) async {
    var backs = 0;
    await pump(tester, onBack: () => backs++);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump();

    expect(backs, 1);
  });

  testWidgets('there is no home affordance unless the host wires one',
      (tester) async {
    // A pane reached from a single click does not need a shortcut out of it,
    // and an Inbox button on a host with nowhere to send the reader would go
    // nowhere.
    await pump(tester, onBack: () {});

    expect(find.byTooltip('Inbox'), findsNothing);
    expect(find.text('Inbox'), findsNothing);
  });

  testWidgets('the home affordance renders and fires when it is wired',
      (tester) async {
    var homes = 0;
    await pump(tester, onBack: () {}, onHome: () => homes++);

    expect(find.byTooltip('Inbox'), findsOneWidget);
    // Labelled rather than an icon alone: the bolt is not a glyph anyone reads
    // as a destination without the word beside it.
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);

    await tester.tap(find.byTooltip('Inbox'));
    await tester.pump();

    expect(homes, 1);
  });

  testWidgets('a host with nowhere to go back to gets a disabled arrow',
      (tester) async {
    // The first-run wizard's first step is the only caller with no way back.
    // The arrow stays and goes grey rather than disappearing, because the
    // header is a row and a missing button would shift the title of exactly
    // one pane.
    await pump(tester, onBack: null);

    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_back))
          .onPressed,
      isNull,
    );
  });

  testWidgets('the trailing slot renders what the pane puts in it',
      (tester) async {
    await pump(
      tester,
      onBack: () {},
      trailing: const Text('a trailing thing'),
    );

    expect(find.text('a trailing thing'), findsOneWidget);
  });

  testWidgets('a long title ellipsises rather than overflowing a narrow pane',
      (tester) async {
    // The title is the header row's shock absorber: at a narrow width, with
    // the home button also on the row, it is what gives — the way out must
    // survive a name that does not fit.
    await pump(
      tester,
      title: 'A pane title long enough to run off the end of any header row '
          'somebody is likely to build',
      onBack: () {},
      onHome: () {},
      surface: const Size(320, 600),
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Inbox'), findsOneWidget);
  });
}
