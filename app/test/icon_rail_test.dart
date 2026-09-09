import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/app_rail.dart' show RailSection;
import 'package:bond_inbox/widgets/bond_avatar.dart';
import 'package:bond_inbox/widgets/icon_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 56px strip of stops and the account menu at the foot of it.
///
/// `pumpAndSettle` is safe in this file and nowhere near `InboxScreen`: there
/// is no sixty-second timer here, and the menu opens on an animation that has
/// to finish before its items are tappable.

/// Loose height so all seven stops lay out; the rail sizes its own width.
Widget _host(Widget rail) => MaterialApp(
      home: Scaffold(
        body: Row(children: [rail, const Expanded(child: SizedBox())]),
      ),
    );

void main() {
  Future<void> pumpRail(
    WidgetTester tester, {
    RailSection? selected = RailSection.home,
    int needsYouCount = 0,
    void Function(RailSection)? onSelect,
    String accountName = 'Dana Whitfield',
    String? accountAddress,
    VoidCallback? onSettings,
    VoidCallback? onActivityLog,
    VoidCallback? onSignOut,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(IconRail(
      selected: selected,
      needsYouCount: needsYouCount,
      onSelect: onSelect ?? (_) {},
      accountName: accountName,
      accountAddress: accountAddress,
      onSettings: onSettings ?? () {},
      onActivityLog: onActivityLog,
      onSignOut: onSignOut ?? () {},
    )));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(IconRail.accountMenuKey));
    await tester.pumpAndSettle();
  }

  group('the stops', () {
    testWidgets('all seven, each with its label', (tester) async {
      await pumpRail(tester);

      for (final label in const [
        'Inbox',
        'Needs You',
        'Storylines',
        'People',
        'Files',
        'Later',
        'AI',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('Files sits between People and Later', (tester) async {
      // Order is what the reader navigates by, and `stops` is an explicit list
      // so it cannot drift: Files is the last of the piles that are about the
      // mail, and Later is where things go to be dealt with afterwards.
      final sections = [for (final (section, _) in IconRail.stops) section];

      expect(
        sections.indexOf(RailSection.files),
        sections.indexOf(RailSection.people) + 1,
      );
      expect(
        sections.indexOf(RailSection.archive),
        sections.indexOf(RailSection.files) + 1,
      );
    });

    testWidgets('and Drafts & sent is deliberately not one of them',
        (tester) async {
      await pumpRail(tester);

      // It is a ROW in the Home stack, not a stop: what it holds is the
      // model's unsent work rather than a pile of mail, and a seventh icon for
      // a list that is usually empty would cost a permanent stop for an
      // occasional one. `stops` is an explicit list so this cannot drift.
      expect(
        [for (final (section, _) in IconRail.stops) section],
        isNot(contains(RailSection.drafts)),
      );
      expect(find.text('Drafts & sent'), findsNothing);
    });

    testWidgets('the selected stop is tinted and the rest are not',
        (tester) async {
      await pumpRail(tester, selected: RailSection.storylines);

      Color? fillUnder(String label) {
        final material = find
            .ancestor(of: find.text(label), matching: find.byType(Material))
            .first;
        return tester.widget<Material>(material).color;
      }

      expect(fillUnder('Storylines'), BondColors.onDarkTint);
      expect(fillUnder('Inbox'), BondColors.railDeep);
      // And the ink follows the fill.
      expect(
        tester.widget<Text>(find.text('Storylines')).style?.color,
        BondColors.onDarkPrimary,
      );
      expect(
        tester.widget<Text>(find.text('Inbox')).style?.color,
        BondColors.onDarkMuted,
      );
    });

    testWidgets('nothing is tinted when no section is showing', (tester) async {
      await pumpRail(tester, selected: null);

      final tinted = tester
          .widgetList<Material>(find.byType(Material))
          .where((m) => m.color == BondColors.onDarkTint);
      expect(tinted, isEmpty);
    });

    testWidgets('tapping a stop reports it', (tester) async {
      final picked = <RailSection>[];
      await pumpRail(tester, onSelect: picked.add);

      await tester.tap(find.text('People'));
      await tester.tap(find.text('AI'));

      expect(picked, [RailSection.people, RailSection.ai]);
    });
  });

  group('the Needs You badge', () {
    testWidgets('shows the count, and nothing at zero', (tester) async {
      await pumpRail(tester, needsYouCount: 0);
      expect(find.text('0'), findsNothing);

      await pumpRail(tester, needsYouCount: 7);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('stops counting past ninety-nine', (tester) async {
      await pumpRail(tester, needsYouCount: 143);

      expect(find.text('99+'), findsOneWidget);
      expect(find.text('143'), findsNothing);
    });

    testWidgets('is the rail red, not the page red', (tester) async {
      await pumpRail(tester, needsYouCount: 3);

      final pill = find
          .ancestor(of: find.text('3'), matching: find.byType(Container))
          .first;
      final decoration =
          tester.widget<Container>(pill).decoration! as BoxDecoration;
      expect(decoration.color, BondColors.railBadge);
    });
  });

  group('the account menu', () {
    testWidgets('the avatar shows the account initials', (tester) async {
      await pumpRail(tester);

      expect(find.byType(BondAvatar), findsOneWidget);
      expect(find.text('DW'), findsOneWidget);
    });

    testWidgets('carries the name, the address and the three items',
        (tester) async {
      await pumpRail(
        tester,
        accountAddress: 'dana@example.com',
        onActivityLog: () {},
      );
      await openMenu(tester);

      expect(find.text('Dana Whitfield'), findsOneWidget);
      expect(find.text('dana@example.com'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Activity log'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('the activity log is absent when the host offers none',
        (tester) async {
      await pumpRail(tester);
      await openMenu(tester);

      expect(find.byKey(IconRail.activityItemKey), findsNothing);
      expect(find.text('Activity log'), findsNothing);
      // The two that are never optional are still there.
      expect(find.byKey(IconRail.settingsItemKey), findsOneWidget);
      expect(find.byKey(IconRail.signOutItemKey), findsOneWidget);
    });

    testWidgets('Settings fires', (tester) async {
      var opened = 0;
      await pumpRail(tester, onSettings: () => opened++);
      await openMenu(tester);

      await tester.tap(find.byKey(IconRail.settingsItemKey));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });

    testWidgets('Activity log fires', (tester) async {
      var opened = 0;
      await pumpRail(tester, onActivityLog: () => opened++);
      await openMenu(tester);

      await tester.tap(find.byKey(IconRail.activityItemKey));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });

    testWidgets('Sign out fires', (tester) async {
      var out = 0;
      await pumpRail(tester, onSignOut: () => out++);
      await openMenu(tester);

      await tester.tap(find.byKey(IconRail.signOutItemKey));
      await tester.pumpAndSettle();

      expect(out, 1);
    });

    testWidgets('the header row is not a destination', (tester) async {
      var out = 0;
      var opened = 0;
      await pumpRail(
        tester,
        onSignOut: () => out++,
        onSettings: () => opened++,
      );
      await openMenu(tester);

      await tester.tap(find.text('Dana Whitfield'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(out, 0);
      expect(opened, 0);
      // And it did not close the menu either — a disabled item swallows the tap.
      expect(find.byKey(IconRail.settingsItemKey), findsOneWidget);
    });
  });
}
