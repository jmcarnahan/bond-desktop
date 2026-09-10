import 'package:bond_inbox/widgets/bond_avatar.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/room_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The header both rooms wear.
///
/// It exists so a thread and a storyline stop disagreeing about where things
/// go, which makes the load-bearing assertions here positional rather than
/// cosmetic: an action is an action wherever it came from, the ⋯ is where
/// corrections live, and a tab row appears only when there is a choice.

enum _Tab { one, two, three }

void main() {
  Future<void> pumpHeader(
    WidgetTester tester, {
    Size size = const Size(1000, 400),
    Widget? leading,
    Widget title = const Text('Launch date'),
    String? subtitle,
    List<AvatarPerson> people = const [],
    Widget? stateChip,
    VoidCallback? onBack,
    VoidCallback? onPeopleTap,
    List<RoomAction> actions = const [],
    List<RoomMenuItem> moreItems = const [],
    List<_Tab> tabs = const [],
    _Tab? selectedTab,
    ValueChanged<_Tab>? onTab,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomHeader<_Tab>(
          leading: leading,
          title: title,
          subtitle: subtitle,
          people: people,
          stateChip: stateChip,
          onBack: onBack,
          onPeopleTap: onPeopleTap,
          actions: actions,
          moreItems: moreItems,
          tabs: tabs,
          selectedTab: selectedTab,
          tabLabel: (tab) => switch (tab) {
            _Tab.one => 'Messages',
            _Tab.two => 'Files',
            _Tab.three => 'About',
          },
          onTab: onTab,
        ),
      ),
    ));
    await tester.pump();
  }

  group('identity', () {
    testWidgets('renders the title, and the subtitle under it', (tester) async {
      await pumpHeader(tester, subtitle: 'Eric Vance, Sarah Whitfield');

      expect(find.text('Launch date'), findsOneWidget);
      final subtitle = find.text('Eric Vance, Sarah Whitfield');
      expect(subtitle, findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Launch date')).dy,
        lessThan(tester.getTopLeft(subtitle).dy),
      );
    });

    testWidgets('an empty subtitle draws no second line', (tester) async {
      await pumpHeader(tester, subtitle: '');

      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('the leading slot is drawn when it is given', (tester) async {
      await pumpHeader(tester, leading: const Text('#'));

      expect(find.text('#'), findsOneWidget);
    });

    testWidgets('the state chip is drawn when it is given', (tester) async {
      await pumpHeader(tester);
      expect(find.byType(BondChip), findsNothing);

      await pumpHeader(tester, stateChip: BondChip.metric('3 messages'));
      expect(find.text('3 messages'), findsOneWidget);
    });

    testWidgets('faces appear only when there is somebody to show',
        (tester) async {
      await pumpHeader(tester);
      expect(find.byType(AvatarStack), findsNothing);

      await pumpHeader(tester, people: const [
        (name: 'Eric Vance', address: 'eric@example.com', photoKey: null),
      ]);
      expect(find.byType(AvatarStack), findsOneWidget);
    });

    testWidgets('a narrow header takes the faces off rather than crowding them',
        (tester) async {
      await pumpHeader(tester, people: const [
        (name: 'Eric Vance', address: 'eric@example.com', photoKey: null),
      ]);
      expect(find.byType(AvatarStack), findsOneWidget);

      // Under the width the header measures for itself, the same people are
      // still on the thread — they are just not drawn beside its title.
      await tester.binding.setSurfaceSize(const Size(480, 400));
      await tester.pump();
      expect(find.byType(AvatarStack), findsNothing);
      expect(find.text('Launch date'), findsOneWidget);
    });

    testWidgets('the faces open the person when the host has one to show',
        (tester) async {
      var opened = 0;
      await pumpHeader(
        tester,
        people: const [
          (name: 'Eric Vance', address: 'eric@example.com', photoKey: null),
        ],
        onPeopleTap: () => opened++,
      );

      await tester.tap(find.byKey(RoomHeader.peopleKey));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('and stay a picture when there is nowhere to send the tap',
        (tester) async {
      // Not a dead InkWell: a control that answers nothing must not look
      // like one.
      await pumpHeader(tester, people: const [
        (name: 'Eric Vance', address: 'eric@example.com', photoKey: null),
      ]);

      expect(find.byKey(RoomHeader.peopleKey), findsNothing);
    });
  });

  group('back', () {
    testWidgets('is hidden for a room nobody navigated into', (tester) async {
      await pumpHeader(tester);

      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('and fires when there is somewhere to go', (tester) async {
      var backs = 0;
      await pumpHeader(tester, onBack: () => backs++);

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();

      expect(backs, 1);
    });
  });

  group('actions', () {
    testWidgets('an icon action is a button whose tooltip is its label',
        (tester) async {
      var taps = 0;
      await pumpHeader(tester, actions: [
        RoomAction(
          icon: Icons.edit_outlined,
          label: 'Message',
          onTap: () => taps++,
          key: const Key('compose'),
        ),
      ]);

      // The label is not spent on width: it is what the tooltip says.
      expect(find.text('Message'), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

      await tester.tap(find.byKey(const Key('compose')));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('a text action wears its label and fires', (tester) async {
      var taps = 0;
      await pumpHeader(tester, actions: [
        RoomAction(label: 'Mark done', onTap: () => taps++),
      ]);

      expect(find.text('Mark done'), findsOneWidget);

      await tester.tap(find.text('Mark done'));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('the narrow fold', () {
    /// The menu is a route, so it needs the two frames a route transition
    /// takes rather than a settle: this header is pumped inside screens that
    /// own a 60 s timer.
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(RoomHeader.moreKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    const narrow = Size(420, 400);

    testWidgets('a labelled action goes into the ⋯ menu rather than clipping',
        (tester) async {
      var taps = 0;
      await pumpHeader(
        tester,
        size: narrow,
        actions: [RoomAction(label: 'Mark done', onTap: () => taps++)],
        moreItems: [
          RoomMenuItem(value: 'file', label: 'Add to storyline…', onTap: () {}),
          RoomMenuItem(value: 'later', label: 'Send to Later', onTap: () {}),
        ],
      );

      // Not on the row: a word costs whatever its letters are, and in a side
      // panel that makes it the widest thing on a row of controls.
      expect(find.widgetWithText(TextButton, 'Mark done'), findsNothing);

      await openMenu(tester);

      // At the TOP of the menu — it was a control a moment ago — and divided
      // off from the room's own corrections below it.
      final items = find.byType(PopupMenuItem<String>);
      expect(tester.widgetList<PopupMenuItem<String>>(items).first.value,
          'action-Mark done');
      expect(find.byType(PopupMenuDivider), findsOneWidget);

      await tester.tap(find.text('Mark done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Folding moves the control; it does not change what it does.
      expect(taps, 1);
    });

    testWidgets('an icon action stays on the row at the same width',
        (tester) async {
      // An icon costs a fixed 52 pixels whatever it says, because its words
      // are a tooltip. There is nothing to save by hiding it.
      await pumpHeader(
        tester,
        size: narrow,
        actions: [
          RoomAction(
            icon: Icons.folder_open_outlined,
            label: 'Context',
            onTap: () {},
            key: const Key('context'),
          ),
        ],
        moreItems: [
          RoomMenuItem(value: 'later', label: 'Send to Later', onTap: () {}),
        ],
      );

      expect(find.byKey(const Key('context')), findsOneWidget);

      await openMenu(tester);

      expect(find.text('Context'), findsNothing);
      expect(find.byType(PopupMenuDivider), findsNothing);
    });

    testWidgets('and with room the same labelled action is a button, not an '
        'item', (tester) async {
      await pumpHeader(
        tester,
        actions: [RoomAction(label: 'Mark done', onTap: () {})],
        moreItems: [
          RoomMenuItem(value: 'later', label: 'Send to Later', onTap: () {}),
        ],
      );

      expect(find.widgetWithText(TextButton, 'Mark done'), findsOneWidget);

      await openMenu(tester);

      // One item, and it is the room's own. Nothing folded, so nothing is
      // divided off.
      expect(find.byType(PopupMenuItem<String>), findsOneWidget);
      expect(find.text('Send to Later'), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsNothing);
    });
  });

  group('the ⋯ menu', () {
    testWidgets('is absent when there is nothing to put in it', (tester) async {
      await pumpHeader(tester);

      expect(find.byKey(RoomHeader.moreKey), findsNothing);
    });

    testWidgets('holds its items and fires the one that was picked',
        (tester) async {
      final picked = <String>[];
      await pumpHeader(tester, moreItems: [
        RoomMenuItem(
          value: 'file',
          label: 'Add to storyline…',
          onTap: () => picked.add('file'),
        ),
        RoomMenuItem(
          value: 'later',
          label: 'Send to Later',
          onTap: () => picked.add('later'),
        ),
      ]);

      await tester.tap(find.byKey(RoomHeader.moreKey));
      await tester.pumpAndSettle();

      expect(find.text('Add to storyline…'), findsOneWidget);
      expect(find.text('Send to Later'), findsOneWidget);

      await tester.tap(find.text('Send to Later'));
      await tester.pumpAndSettle();

      // Only the one that was picked: an item that fired its neighbour would
      // file a thread the user meant to defer.
      expect(picked, ['later']);
    });

    testWidgets('a dividerBefore item is preceded by a rule', (tester) async {
      await pumpHeader(tester, moreItems: [
        RoomMenuItem(value: 'a', label: 'Add to storyline…', onTap: () {}),
        RoomMenuItem(
          value: 'b',
          label: 'Send to Later',
          onTap: () {},
          dividerBefore: true,
        ),
      ]);

      await tester.tap(find.byKey(RoomHeader.moreKey));
      await tester.pumpAndSettle();

      expect(find.byType(PopupMenuDivider), findsOneWidget);
    });

    testWidgets('an item with nothing to do is disabled', (tester) async {
      // A label like 'Syncing…' is a statement, and a statement that answered
      // a tap would be offering a second pull.
      await pumpHeader(tester, moreItems: const [
        RoomMenuItem(value: 'sync', label: 'Syncing…'),
      ]);

      await tester.tap(find.byKey(RoomHeader.moreKey));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
            .enabled,
        isFalse,
      );
    });
  });

  group('the tab row', () {
    testWidgets('is absent when there is no choice to make', (tester) async {
      await pumpHeader(tester, tabs: const [_Tab.one], selectedTab: _Tab.one);

      // One pill is a label pretending to be a choice.
      expect(find.byType(BondFilterPill), findsNothing);
    });

    testWidgets('draws one keyed pill per tab, and marks the one that is on',
        (tester) async {
      await pumpHeader(
        tester,
        tabs: _Tab.values,
        selectedTab: _Tab.two,
      );

      expect(find.byType(BondFilterPill), findsNWidgets(3));
      expect(find.text('Messages'), findsOneWidget);
      expect(
        tester
            .widget<BondFilterPill>(find.byKey(RoomHeader.tabKey(_Tab.two)))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<BondFilterPill>(find.byKey(RoomHeader.tabKey(_Tab.one)))
            .selected,
        isFalse,
      );
    });

    testWidgets('a tap reports the tab that was picked', (tester) async {
      final picked = <_Tab>[];
      await pumpHeader(
        tester,
        tabs: _Tab.values,
        selectedTab: _Tab.one,
        onTab: picked.add,
      );

      await tester.tap(find.byKey(RoomHeader.tabKey(_Tab.three)));
      await tester.pump();

      expect(picked, [_Tab.three]);
    });
  });
}
