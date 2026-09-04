import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/chips.dart';
import 'package:bond_inbox/widgets/conversation_row.dart';
import 'package:bond_inbox/widgets/source_filter.dart';
import 'package:bond_inbox/widgets/source_glyph.dart';
import 'package:bond_inbox/widgets/storyline_timeline.dart';
import 'package:bond_inbox/widgets/time_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything that tells a chat from an email on screen: the filter pills, the
/// glyph on a row, and the source mark on a storyline's episode cards.

Conversation _conv({
  required String id,
  String source = 'email',
  String? who,
  String? subject,
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: who == null ? const [] : [Participant(name: who)],
      lastMessageAt: '2026-08-28T10:00:00Z',
    );

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('bySource', () {
    final rows = [
      _conv(id: 'c1'),
      _conv(id: 'chat-1', source: 'teams'),
      _conv(id: 'c2'),
    ];

    test('null is everything, and the same list', () {
      expect(identical(bySource(rows, null), rows), isTrue);
    });

    test('a source keeps only its own', () {
      expect(bySource(rows, 'teams').map((c) => c.id).toList(), ['chat-1']);
      expect(bySource(rows, 'email').map((c) => c.id).toList(), ['c1', 'c2']);
    });

    test('a source nothing came from is empty, not everything', () {
      expect(bySource(rows, 'slack'), isEmpty);
    });
  });

  group('the glyph', () {
    test('marks a chat and leaves mail alone', () {
      expect(withSourceGlyph('teams', 'Sarah'), '💬 Sarah');
      expect(withSourceGlyph('email', 'Sarah'), 'Sarah');
    });

    test('a rail row carries it, whichever line it fell back to', () {
      expect(railTitleFor(_conv(id: 'a', source: 'teams', who: 'Sarah')),
          '💬 Sarah');
      expect(
        railTitleFor(_conv(id: 'a', source: 'teams', subject: 'Re: Website redesign')),
        '💬 Website redesign',
      );
      expect(railTitleFor(_conv(id: 'a', source: 'teams')), '💬 (no subject)');
      expect(railTitleFor(_conv(id: 'a', who: 'Sarah')), 'Sarah');
    });

    testWidgets('a conversation card marks the subject line', (tester) async {
      await tester.pumpWidget(_host(Column(children: [
        ConversationRow(
          conversation:
              _conv(id: 'chat-1', source: 'teams', who: 'Sarah', subject: 'Launch date'),
          selected: false,
          onTap: () {},
        ),
        ConversationRow(
          conversation: _conv(id: 'c1', who: 'Eric', subject: 'Homepage copy'),
          selected: false,
          onTap: () {},
        ),
      ])));

      expect(find.text('💬 Launch date'), findsOneWidget);
      expect(find.text('Homepage copy'), findsOneWidget);
      // The name stays clean — it is the loudest thing on the card and a
      // glyph there would compete with the state dot.
      expect(find.text('Sarah'), findsOneWidget);
    });
  });

  group('SourceFilterBar', () {
    testWidgets('reports what was tapped, including back to All',
        (tester) async {
      final picked = <String?>[];
      await tester.pumpWidget(_host(SourceFilterBar(
        selected: null,
        onSelected: picked.add,
      )));

      await tester.tap(find.byKey(SourceFilterBar.teamsKey));
      await tester.tap(find.byKey(SourceFilterBar.mailKey));
      await tester.tap(find.byKey(SourceFilterBar.allKey));

      expect(picked, ['teams', 'email', null]);
    });

    testWidgets('exactly one pill reads as selected', (tester) async {
      await tester.pumpWidget(_host(SourceFilterBar(
        selected: 'teams',
        onSelected: (_) {},
      )));

      final pills = tester
          .widgetList<BondFilterPill>(find.byType(BondFilterPill))
          .toList();
      expect(pills.where((p) => p.selected).length, 1);
      expect(
        pills.singleWhere((p) => p.selected).label,
        contains('Teams'),
      );
    });

    testWidgets('without the scope the Teams pill is present, dead, and says '
        'why', (tester) async {
      final picked = <String?>[];
      await tester.pumpWidget(_host(SourceFilterBar(
        selected: null,
        teamsAvailable: false,
        onSelected: picked.add,
      )));

      // Present: a pill that vanished would leave a user who expected Teams
      // with nothing to ask about.
      expect(find.byKey(SourceFilterBar.teamsKey), findsOneWidget);
      final pill = tester.widget<BondFilterPill>(
        find.byKey(SourceFilterBar.teamsKey),
      );
      expect(pill.onTap, isNull);

      await tester.tap(find.byKey(SourceFilterBar.teamsKey));
      expect(picked, isEmpty);

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, SourceFilterBar.unavailableTooltip);
      expect(tooltip.message, contains('Settings'));
    });

    testWidgets('the other two still work when Teams is unavailable',
        (tester) async {
      final picked = <String?>[];
      await tester.pumpWidget(_host(SourceFilterBar(
        selected: null,
        teamsAvailable: false,
        onSelected: picked.add,
      )));

      await tester.tap(find.byKey(SourceFilterBar.mailKey));
      expect(picked, ['email']);
    });

    testWidgets('it fits the 260px rail', (tester) async {
      await tester.pumpWidget(_host(
        SizedBox(
          width: 236, // the rail minus its footer padding
          child: SourceFilterBar(selected: null, onSelected: (_) {}),
        ),
      ));

      expect(tester.takeException(), isNull);
    });
  });

  group('storyline episode cards', () {
    testWidgets('name the source on every card, mail included', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(StorylineTimelinePanel(
        storyline: const Storyline(
          id: 'sl-1',
          title: 'Website redesign',
          status: 'active',
          memberCount: 2,
        ),
        episodes: const [
          StorylineEpisode(
            source: 'email',
            conversationKey: 'c1',
            subject: 'Homepage copy',
            participants: ['Sarah'],
            latestAt: '2026-08-01T09:00:00Z',
            messages: [
              Message(
                id: 'm1',
                outbound: false,
                fromName: 'Sarah',
                receivedAt: '2026-08-01T09:00:00Z',
                bodyText: 'the mail one',
              ),
            ],
          ),
          StorylineEpisode(
            source: 'teams',
            conversationKey: 'chat-1',
            subject: 'Sarah Whitfield',
            participants: ['Sarah'],
            latestAt: '2026-08-01T09:05:00Z',
            messages: [
              Message(
                id: 'm2',
                source: 'teams',
                outbound: false,
                fromName: 'Sarah',
                receivedAt: '2026-08-01T09:05:00Z',
                bodyText: 'the chat one',
              ),
            ],
          ),
        ],
        members: const [
          StorylineMember(
            storylineId: 'sl-1',
            conversationKey: 'c1',
            addedBy: 'auto',
          ),
          StorylineMember(
            storylineId: 'sl-1',
            source: 'teams',
            conversationKey: 'chat-1',
            addedBy: 'auto',
          ),
        ],
        onBack: null,
        onRename: (_) {},
        onSetCharter: (_) {},
        onAcceptSuggestion: (_) {},
        onDismissSuggestion: () {},
        onRemoveThread: (_, _) {},
        onOpenThread: (_, _) {},
        onAddThread: () {},
        newestFirst: false,
        onToggleSort: () {},
        onDismiss: () {},
      )));

      // Both marked here, mail included: a storyline holds threads and chats,
      // and an unmarked card leaves the reader guessing which this was.
      expect(find.text('✉ Homepage copy'), findsOneWidget);
      expect(find.text('💬 Sarah Whitfield'), findsOneWidget);
    });
  });

  group('relativeTime', () {
    final now = DateTime.utc(2026, 8, 29, 12, 0, 0);

    test('picks one unit and stops', () {
      expect(relativeTime('2026-08-29T11:59:30Z', now), 'just now');
      expect(relativeTime('2026-08-29T11:56:00Z', now), '4m ago');
      expect(relativeTime('2026-08-29T09:00:00Z', now), '3h ago');
      expect(relativeTime('2026-08-27T12:00:00Z', now), '2d ago');
      // 1h 24m ago answers "is this current?" no better than 1h ago.
      expect(relativeTime('2026-08-29T10:36:00Z', now), '1h ago');
    });

    test('the boundaries land on the larger unit', () {
      expect(relativeTime('2026-08-29T11:59:00Z', now), '1m ago');
      expect(relativeTime('2026-08-29T11:00:00Z', now), '1h ago');
      expect(relativeTime('2026-08-28T12:00:00Z', now), '1d ago');
    });

    test('a clock skewed ahead reads as now, never as a negative age', () {
      expect(relativeTime('2026-08-29T12:05:00Z', now), 'just now');
    });

    test('nothing to say for nothing', () {
      expect(relativeTime(null, now), isNull);
      expect(relativeTime('', now), isNull);
      expect(relativeTime('not a date', now), isNull);
    });
  });
}
