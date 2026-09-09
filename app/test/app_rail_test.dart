import 'package:bond_inbox/models/files_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/needs_you_sort.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/theme/tokens.dart';
import 'package:bond_inbox/widgets/app_rail.dart';
import 'package:bond_inbox/widgets/bond_avatar.dart';
import 'package:bond_inbox/widgets/dismissed_storylines_fold.dart';
import 'package:bond_inbox/widgets/find_filter.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Storyline _storyline({
  required String id,
  String title = 'Website redesign',
  String status = 'active',
  int memberCount = 2,
  int openCount = 0,
}) {
  return Storyline(
    id: id,
    title: title,
    status: status,
    memberCount: memberCount,
    openCount: openCount,
  );
}

/// The account every room in this file is grouped against.
const Owner _owner = (name: 'Dana Whitfield', address: 'dana@example.com');

Conversation _conv({
  required String id,
  String? who,
  String? subject,
  ConversationState state = ConversationState.waiting,
  String? cta,
  String? bucket,
  double? score,
  String? lastMessageAt,
  int unread = 0,
  int pending = 0,
  String source = 'email',
}) {
  return Conversation(
    id: id,
    source: source,
    subject: subject,
    participants: who == null ? const [] : [Participant(name: who)],
    state: state,
    ctaText: cta,
    bucket: bucket,
    attentionScore: score,
    lastMessageAt: lastMessageAt,
    unreadCount: unread,
    aiPendingCount: pending,
  );
}

/// The rail is 260 wide by design, so the host must hand it loose width —
/// a Scaffold body's tight constraints would stretch it and hide a
/// regression in the row layout.
Widget _host(Widget rail) => MaterialApp(
      home: Scaffold(
        body: Row(children: [rail, const Expanded(child: SizedBox())]),
      ),
    );

void main() {
  group('needsYouRows', () {
    test('includes anything awaiting a reply', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });

    test('includes a waiting thread the model left an ask on', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.waiting, cta: 'Send the doc'),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });

    test('excludes a done thread even with an ask on it', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.done, cta: 'Send the doc'),
      ]);
      expect(rows, isEmpty);
    });

    test('excludes a waiting thread with no ask', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.waiting),
      ]);
      expect(rows, isEmpty);
    });

    test('preserves input order among equals', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply),
        _conv(id: 'b', state: ConversationState.waiting),
        _conv(id: 'c', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['a', 'c']);
    });

    test('excludes anything deferred to Later', () {
      final rows = needsYouRows([
        _conv(id: 'a', state: ConversationState.needsReply, bucket: 'later'),
        _conv(id: 'b', state: ConversationState.needsReply),
      ]);
      expect(rows.map((c) => c.id), ['b']);
    });

    test('sorts needs-reply first, then by score', () {
      final rows = needsYouRows([
        _conv(id: 'quiet', state: ConversationState.needsReply, score: 0.4),
        _conv(
          id: 'loud-waiting',
          state: ConversationState.waiting,
          cta: 'ask',
          score: 1.9,
        ),
        _conv(id: 'loud', state: ConversationState.needsReply, score: 1.5),
      ]);
      // A waiting thread never outranks a reply the LO owes, however loudly
      // it scores.
      expect(rows.map((c) => c.id), ['loud', 'quiet', 'loud-waiting']);
    });

    test('ties keep input order rather than shuffling between reads', () {
      final rows = needsYouRows([
        for (final id in ['a', 'b', 'c', 'd', 'e'])
          _conv(id: id, state: ConversationState.needsReply, score: 1),
      ]);
      expect(rows.map((c) => c.id), ['a', 'b', 'c', 'd', 'e']);
    });

    test('a missing score sorts as zero rather than throwing', () {
      final rows = needsYouRows([
        _conv(id: 'unscored', state: ConversationState.needsReply),
        _conv(id: 'scored', state: ConversationState.needsReply, score: 1),
      ]);
      expect(rows.map((c) => c.id), ['scored', 'unscored']);
    });

    test('the threshold cuts anything below it, needs-reply included', () {
      final rows = needsYouRows(
        [
          _conv(id: 'over', state: ConversationState.needsReply, score: 0.9),
          _conv(id: 'under', state: ConversationState.needsReply, score: 0.1),
        ],
        threshold: 0.5,
      );
      expect(rows.map((c) => c.id), ['over']);
    });

    test('a row exactly at the threshold is in', () {
      final rows = needsYouRows(
        [_conv(id: 'a', state: ConversationState.needsReply, score: 0.5)],
        threshold: 0.5,
      );
      expect(rows.map((c) => c.id), ['a']);
    });
  });

  group('isWaitingRow', () {
    test('is the second block of Needs You', () {
      expect(
        isWaitingRow(_conv(id: 'a', state: ConversationState.needsReply)),
        isFalse,
      );
      expect(
        isWaitingRow(_conv(id: 'a', state: ConversationState.waiting)),
        isTrue,
      );
    });
  });

  group('conversationRows', () {
    test('drops done threads and keeps the rest in order', () {
      final rows = conversationRows([
        _conv(id: 'a', state: ConversationState.waiting),
        _conv(id: 'b', state: ConversationState.done),
        _conv(id: 'c', state: ConversationState.waiting),
      ]);
      expect(rows.map((c) => c.id), ['a', 'c']);
    });

    test('drops deferred threads too — exactly one section claims each', () {
      final rows = conversationRows([
        _conv(id: 'a', state: ConversationState.waiting),
        _conv(id: 'b', state: ConversationState.waiting, bucket: 'later'),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });

    test('drops what Needs You claimed, and keeps what its threshold cut', () {
      final all = [
        _conv(id: 'loud', state: ConversationState.needsReply, score: 0.9),
        _conv(id: 'quiet', state: ConversationState.needsReply, score: 0.1),
      ];

      expect(conversationRows(all), isEmpty);
      // The slider moved one down a section rather than out of the app.
      expect(
        conversationRows(all, threshold: 0.5).map((c) => c.id),
        ['quiet'],
      );
    });
  });

  group('the two sections partition', () {
    final mixed = [
      _conv(id: 'loud-reply', state: ConversationState.needsReply, score: 0.9),
      _conv(id: 'quiet-reply', state: ConversationState.needsReply, score: 0.1),
      _conv(
        id: 'cta',
        state: ConversationState.waiting,
        cta: 'Send the homepage copy',
        score: 0.8,
      ),
      _conv(id: 'waiting', state: ConversationState.waiting, score: 0.7),
      _conv(id: 'done', state: ConversationState.done, cta: 'Ignored'),
      _conv(
        id: 'deferred',
        state: ConversationState.needsReply,
        bucket: 'later',
      ),
    ];

    /// Everything neither closed nor deferred — what the two sections have to
    /// account for between them, whatever the slider is set to.
    final live = {'loud-reply', 'quiet-reply', 'cta', 'waiting'};

    for (final threshold in [0.0, 0.5]) {
      test('at threshold $threshold each live thread is in exactly one', () {
        final needsYou =
            needsYouRows(mixed, threshold: threshold).map((c) => c.id).toSet();
        final open = conversationRows(mixed, threshold: threshold)
            .map((c) => c.id)
            .toSet();

        expect(needsYou.union(open), live);
        expect(needsYou.intersection(open), isEmpty);
      });
    }

    test('the threshold moves a thread between them, it never hides one', () {
      expect(
        needsYouRows(mixed, threshold: 0.5).map((c) => c.id),
        isNot(contains('quiet-reply')),
      );
      expect(
        conversationRows(mixed, threshold: 0.5).map((c) => c.id),
        contains('quiet-reply'),
      );
    });
  });

  group('laterRows', () {
    test('is everything deferred and still open', () {
      final rows = laterRows([
        _conv(id: 'a', bucket: 'later'),
        _conv(id: 'b'),
        _conv(id: 'c', bucket: 'later', state: ConversationState.done),
      ]);
      expect(rows.map((c) => c.id), ['a']);
    });
  });

  group('laterDayCounts', () {
    test('groups by local day, newest day first', () {
      final rows = laterDayCounts([
        _conv(id: 'a', bucket: 'later', lastMessageAt: '2026-08-28T10:00:00'),
        _conv(id: 'b', bucket: 'later', lastMessageAt: '2026-08-28T18:00:00'),
        _conv(id: 'c', bucket: 'later', lastMessageAt: '2026-08-27T10:00:00'),
        _conv(id: 'd', lastMessageAt: '2026-08-28T10:00:00'),
      ]);
      expect(rows, [('2026-08-28', 2), ('2026-08-27', 1)]);
    });

    test('mail with an unreadable date is still counted, never dropped', () {
      // Later must never lose anything. A bad timestamp gets its own group
      // rather than an early return.
      final rows = laterDayCounts([
        _conv(id: 'a', bucket: 'later', lastMessageAt: 'wharrgarbl'),
        _conv(id: 'b', bucket: 'later'),
      ]);
      expect(rows, [('', 2)]);
    });

    test('nothing deferred is no days', () {
      expect(laterDayCounts([_conv(id: 'a')]), isEmpty);
    });
  });

  group('laterDayLabel', () {
    test('names the day and carries the count', () {
      expect(laterDayLabel('2026-01-14', 3), 'Wed, Jan 14 — 3');
    });

    test('falls back rather than rendering an empty row', () {
      expect(laterDayLabel('', 2), 'Undated — 2');
      expect(laterDayLabel('nonsense', 1), 'nonsense — 1');
    });
  });

  group('railTitleFor', () {
    test('prefers the first participant', () {
      expect(
        railTitleFor(_conv(id: 'a', who: 'Eric Nolan', subject: 'Rate sheet')),
        'Eric Nolan',
      );
    });

    test('falls back to the subject, reply prefixes stripped', () {
      expect(railTitleFor(_conv(id: 'a', subject: 're: re: foo')), 'foo');
      expect(railTitleFor(_conv(id: 'a', subject: 'FWD: Re: Closing')),
          'Closing');
    });

    test('is a placeholder when there is neither', () {
      expect(railTitleFor(_conv(id: 'a')), '(no subject)');
      expect(railTitleFor(_conv(id: 'a', subject: 'Re: ')), '(no subject)');
    });
  });

  group('needsYouTitleFor', () {
    test('the ask wins over everything', () {
      expect(
        needsYouTitleFor(_conv(
          id: 'a',
          who: 'Eric Nolan',
          subject: 'Rate sheet',
          cta: 'Send the rate sheet',
        )),
        'Send the rate sheet',
      );
    });

    test('then the subject, reply prefixes stripped', () {
      expect(
        needsYouTitleFor(
          _conv(id: 'a', who: 'Eric Nolan', subject: 'Re: Rate sheet'),
        ),
        'Rate sheet',
      );
    });

    test('and the person last, exactly as the rail would have said it', () {
      expect(needsYouTitleFor(_conv(id: 'a', who: 'Eric Nolan')), 'Eric Nolan');
      expect(
        needsYouTitleFor(_conv(id: 'a', who: 'Sarah', source: 'teams')),
        '💬 Sarah',
      );
      expect(needsYouTitleFor(_conv(id: 'a')), '(no subject)');
    });

    test('a blank ask is not an ask', () {
      expect(
        needsYouTitleFor(_conv(id: 'a', who: 'Eric Nolan', cta: '   ')),
        'Eric Nolan',
      );
    });
  });

  group('needsYouWhoFor', () {
    test('names the person when the title is not already them', () {
      expect(
        needsYouWhoFor(_conv(
          id: 'a',
          who: 'Eric Nolan',
          cta: 'Send the rate sheet',
        )),
        ' · Eric Nolan',
      );
      expect(
        needsYouWhoFor(_conv(id: 'a', who: 'Eric Nolan', subject: 'Rate sheet')),
        ' · Eric Nolan',
      );
    });

    test('and adds nothing when the row IS the person', () {
      expect(needsYouWhoFor(_conv(id: 'a', who: 'Eric Nolan')), isNull);
      // Including through the glyph, which is part of how the rail says it.
      expect(
        needsYouWhoFor(_conv(id: 'a', who: 'Sarah', source: 'teams')),
        isNull,
      );
    });

    test('nor when there is nobody to name', () {
      expect(needsYouWhoFor(_conv(id: 'a', subject: 'Rate sheet')), isNull);
    });
  });

  group('AppRail', () {
    final conversations = [
      _conv(id: 'a', who: 'Alice', state: ConversationState.needsReply),
      _conv(id: 'b', who: 'Bruno', state: ConversationState.waiting),
      _conv(
        id: 'c',
        who: 'Cleo',
        state: ConversationState.waiting,
        cta: 'Send the homepage copy',
      ),
      _conv(id: 'd', who: 'Dev', state: ConversationState.done),
    ];

    Future<void> pumpRail(
      WidgetTester tester, {
      String? selectedId,
      RailSection? selectedSection = RailSection.needsYou,
      void Function(String, String)? onSelectConversation,
      void Function(RailSection)? onSelectSection,
      RailSection scope = RailSection.home,
      List<PersonRoom>? rooms,
      void Function(String)? onSelectRoom,
      String? selectedRoomKey,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: rooms ?? const [],
        onSelectRoom: onSelectRoom ?? (_) {},
        conversations: conversations,
        selectedId: selectedId,
        selectedSection: selectedSection,
        selectedRoomKey: selectedRoomKey,
        onSelectConversation: onSelectConversation ?? (_, _) {},
        onSelectSection: onSelectSection ?? (_) {},
      )));
    }

    testWidgets('renders every section header', (tester) async {
      await pumpRail(tester);

      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('DRAFTS & SENT'), findsOneWidget);
      expect(find.text('STORYLINES'), findsOneWidget);
      expect(find.text('PEOPLE'), findsOneWidget);
      expect(find.text('LATER'), findsOneWidget);
      // Home is a stop on the icon rail now, not a row in this column.
      expect(find.text('HOME'), findsNothing);
    });

    testWidgets('the Home stack is in the order the day is worked',
        (tester) async {
      await pumpRail(tester);

      double topOf(String label) => tester.getTopLeft(find.text(label)).dy;

      expect(topOf('NEEDS YOU'), lessThan(topOf('DRAFTS & SENT')));
      expect(topOf('DRAFTS & SENT'), lessThan(topOf('STORYLINES')));
      expect(topOf('STORYLINES'), lessThan(topOf('PEOPLE')));
      expect(topOf('PEOPLE'), lessThan(topOf('LATER')));
    });

    testWidgets('the foot of the column is empty', (tester) async {
      await pumpRail(tester);

      // Settings, Sign out and the account name went to the icon rail's avatar
      // menu; compose and refresh went to the header the screen hands down.
      expect(find.byTooltip('Settings'), findsNothing);
      expect(find.byTooltip('Sign out'), findsNothing);
      expect(find.byTooltip('Activity log'), findsNothing);
    });

    testWidgets('the empty sections say so rather than going blank',
        (tester) async {
      await pumpRail(tester);

      expect(find.text('Suggestions arrive after processing'), findsOneWidget);
      expect(find.text('Nothing deferred yet'), findsOneWidget);
    });

    testWidgets('the Needs You badge counts what is actually waiting',
        (tester) async {
      await pumpRail(tester);

      // Alice (needs reply) and Cleo (waiting, with an ask). Bruno has no ask
      // and Dev is done.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a done thread appears in no section', (tester) async {
      await pumpRail(tester);
      expect(find.text('Dev'), findsNothing);
    });

    testWidgets('tapping a row selects that conversation', (tester) async {
      final selected = <(String, String)>[];
      await pumpRail(
        tester,
        onSelectConversation: (source, id) => selected.add((source, id)),
      );

      // Cleo has an ask on her, so Needs You is the one section she is in —
      // and Needs You titles her row by the ask, not by her name.
      await tester.tap(find.text('Send the homepage copy · Cleo'));
      // The source rides along: the host cannot resolve it from the id, and a
      // key shared with the other connector would open the wrong thread.
      expect(selected, [('email', 'c')]);
    });

    testWidgets('tapping a section label opens its overview', (tester) async {
      final sections = <RailSection>[];
      await pumpRail(tester, onSelectSection: sections.add);

      await tester.tap(find.text('PEOPLE'));
      expect(sections, [RailSection.people]);
    });

    testWidgets('the chevron collapses a section without selecting it',
        (tester) async {
      final sections = <RailSection>[];
      await pumpRail(
        tester,
        onSelectSection: sections.add,
        // Bruno has no ask, so the rail carries him as a room and not as a
        // Needs You row — which is what makes him the control here.
        rooms: peopleRooms(
          [_conv(id: 'b', who: 'Bruno')],
          owner: _owner,
        ),
      );

      expect(find.text('Alice'), findsOneWidget);

      // The first chevron belongs to Needs You.
      await tester.tap(find.byIcon(Icons.expand_more).first);
      await tester.pumpAndSettle();

      // Alice was in Needs You and is gone with it; People is untouched, so
      // it was that one section that closed and not the list.
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Bruno'), findsOneWidget);
      expect(sections, isEmpty);
    });
  });

  group('AppRail Archive', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Conversation> conversations,
      String? selectedLaterDay,
      void Function(String)? onSelectLaterDay,
      RailSection scope = RailSection.home,
      List<PersonRoom>? rooms,
      void Function(String)? onSelectRoom,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: rooms ?? const [],
        onSelectRoom: onSelectRoom ?? (_) {},
        conversations: conversations,
        selectedId: null,
        selectedSection: RailSection.archive,
        selectedLaterDay: selectedLaterDay,
        laterCount: laterRows(conversations).length,
        laterDays: laterDayCounts(conversations),
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
        onSelectLaterDay: onSelectLaterDay,
      )));
    }

    testWidgets('the section is named for everything it holds', (tester) async {
      await pumpRail(tester, conversations: [_conv(id: 'a')]);

      // The section holds done threads too, and is named for the pile the user
      // actually put things in.
      expect(find.text('LATER'), findsOneWidget);
      expect(find.text('ARCHIVE'), findsNothing);
    });

    testWidgets('an empty pile keeps the placeholder and no badge',
        (tester) async {
      await pumpRail(tester, conversations: [_conv(id: 'a')]);

      expect(find.text('Nothing deferred yet'), findsOneWidget);
    });

    testWidgets('a done thread is in the section but not on the badge',
        (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Alice',
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
        _conv(
          id: 'b',
          who: 'Bruno',
          state: ConversationState.done,
          lastMessageAt: '2026-01-14T18:00:00',
        ),
      ]);

      // The day rows and the badge are the DEFERRED pile: a done pile grows
      // without bound and asks nothing of anyone, so a number over it would
      // never go back down.
      expect(find.text('Wed, Jan 14 — 1'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Bruno'), findsNothing);
    });

    testWidgets('a day row per day, with the count in the label',
        (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Alice',
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
        _conv(
          id: 'b',
          who: 'Bruno',
          bucket: 'later',
          lastMessageAt: '2026-01-14T18:00:00',
        ),
        _conv(
          id: 'c',
          who: 'Cleo',
          bucket: 'later',
          lastMessageAt: '2026-01-13T10:00:00',
        ),
      ]);

      expect(find.text('Wed, Jan 14 — 2'), findsOneWidget);
      expect(find.text('Tue, Jan 13 — 1'), findsOneWidget);
      expect(find.text('Nothing deferred yet'), findsNothing);
      // The badge counts the whole pile, not the days.
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('deferred threads appear in no other section', (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Alice',
          state: ConversationState.needsReply,
          bucket: 'later',
          lastMessageAt: '2026-01-14T10:00:00',
        ),
      ]);

      // Its name is nowhere: not in Needs You, not in a People room. Only the
      // day row it was folded into.
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Wed, Jan 14 — 1'), findsOneWidget);
    });

    testWidgets('tapping a day opens its digest', (tester) async {
      final days = <String>[];
      await pumpRail(
        tester,
        conversations: [
          _conv(id: 'a', bucket: 'later', lastMessageAt: '2026-01-14T10:00:00'),
        ],
        onSelectLaterDay: days.add,
      );

      await tester.tap(find.text('Wed, Jan 14 — 1'));
      expect(days, ['2026-01-14']);
    });
  });

  group('AppRail Needs You ranking', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Conversation> conversations,
      double threshold = 0,
      NeedsYouSort needsYouSort = NeedsYouSort.priority,
      void Function(RailSection)? onSelectSection,
      RailSection scope = RailSection.home,
      List<PersonRoom>? rooms,
      void Function(String)? onSelectRoom,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: rooms ?? const [],
        onSelectRoom: onSelectRoom ?? (_) {},
        conversations: conversations,
        selectedId: null,
        selectedSection: RailSection.needsYou,
        attentionThreshold: threshold,
        needsYouSort: needsYouSort,
        onSelectConversation: (_, _) {},
        onSelectSection: onSelectSection ?? (_) {},
      )));
    }

    /// Two rows whose ranking and whose clock disagree — the shape the order
    /// control exists for. The loud one is a week older than the quiet one.
    List<Conversation> rankedAgainstTheClock() => [
          _conv(
            id: 'loud',
            who: 'Loud',
            state: ConversationState.needsReply,
            score: 1.4,
            lastMessageAt: '2026-09-01T09:00:00Z',
          ),
          _conv(
            id: 'today',
            who: 'Today',
            state: ConversationState.needsReply,
            score: 0.6,
            lastMessageAt: '2026-09-08T09:00:00Z',
          ),
        ];

    double topOfRow(WidgetTester tester, String who) =>
        tester.getTopLeft(find.text(who)).dy;

    testWidgets('ranks by priority by default, whatever the clock says',
        (tester) async {
      await pumpRail(tester, conversations: rankedAgainstTheClock());

      expect(topOfRow(tester, 'Loud'), lessThan(topOfRow(tester, 'Today')));
    });

    testWidgets('and Newest first flips the rows the rail draws',
        (tester) async {
      // The rail is the other half of the promise the overview's control
      // makes: one pile, one order, wherever it is drawn.
      await pumpRail(
        tester,
        conversations: rankedAgainstTheClock(),
        needsYouSort: NeedsYouSort.newest,
      );

      expect(topOfRow(tester, 'Today'), lessThan(topOfRow(tester, 'Loud')));
    });

    List<Conversation> manyNeedsReply(int n) => [
          for (var i = 0; i < n; i++)
            _conv(
              id: 'c$i',
              who: 'Person $i',
              state: ConversationState.needsReply,
              // Descending, so the rendered order is the seeded order.
              score: 2 - i * 0.01,
            ),
        ];

    testWidgets('shows at most the top seven, and says how many are left',
        (tester) async {
      await pumpRail(tester, conversations: manyNeedsReply(10));

      expect(find.text('Person 0'), findsOneWidget);
      expect(find.text('Person 6'), findsOneWidget);
      // Person 7..9 are past the cap, and the rail's People rooms are not a
      // second list of them: the overflow row is the only way to them, which
      // is what makes it load-bearing rather than decorative.
      expect(find.text('Person 7'), findsNothing);
      expect(find.text('+3 more'), findsOneWidget);
      // The badge still counts all ten. It must never flatter the workload.
      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('exactly seven needs no overflow row', (tester) async {
      await pumpRail(tester, conversations: manyNeedsReply(7));
      expect(find.textContaining('more'), findsNothing);
    });

    testWidgets('the overflow row opens the section, not a thread',
        (tester) async {
      final sections = <RailSection>[];
      await pumpRail(
        tester,
        conversations: manyNeedsReply(9),
        onSelectSection: sections.add,
      );

      await tester.tap(find.text('+2 more'));
      expect(sections, [RailSection.needsYou]);
    });

    testWidgets('the threshold hides rows from Needs You but not the app',
        (tester) async {
      await pumpRail(
        tester,
        threshold: 0.5,
        conversations: [
          _conv(
            id: 'a',
            who: 'Loud',
            state: ConversationState.needsReply,
            score: 1.5,
          ),
          _conv(
            id: 'b',
            who: 'Quiet',
            state: ConversationState.needsReply,
            score: 0.1,
          ),
        ],
      );

      // Loud stays in Needs You; Quiet dropped out of it and is not hidden —
      // the screen's People grouping still carries it, which is what makes
      // turning the slider up safe.
      expect(find.text('Loud'), findsOneWidget);
      expect(find.text('Quiet'), findsNothing);
      expect(
        peopleRooms(
          [
            _conv(
              id: 'b',
              who: 'Quiet',
              state: ConversationState.needsReply,
              score: 0.1,
            ),
          ],
          owner: _owner,
          threshold: 0.5,
        ).single.title,
        'Quiet',
      );
    });

    testWidgets('a waiting row renders dimmed below the needs-reply block',
        (tester) async {
      await pumpRail(tester, conversations: [
        _conv(
          id: 'a',
          who: 'Owed',
          state: ConversationState.needsReply,
          unread: 1,
          score: 1,
        ),
        _conv(
          id: 'b',
          who: 'Waiting',
          state: ConversationState.waiting,
          cta: 'Send the homepage copy',
          unread: 1,
          score: 1.9,
        ),
      ]);

      // Present, titled by its ask, with the person after it — and quieter
      // than the row above.
      // One Text, rich: the ask in the row's own ink and the person after it
      // in the muted one. `find.text` reads the whole span.
      final row = find.text('Send the homepage copy · Waiting');
      expect(row, findsOneWidget);
      expect(
        tester.widget<Text>(row).textSpan!.style?.color,
        BondColors.onDarkMuted,
      );

      // 'Owed' has no ask and no subject, so its row IS the person and stays
      // a plain Text with no suffix.
      final loud = tester.widget<Text>(find.text('Owed'));
      expect(loud.style?.color, BondColors.onDarkPrimary);
    });
  });

  group('AppRail bold grammar', () {
    Future<void> pumpRail(
      WidgetTester tester,
      List<Conversation> conversations, {
      RailSection scope = RailSection.home,
      List<PersonRoom>? rooms,
      void Function(String)? onSelectRoom,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: rooms ?? const [],
        onSelectRoom: onSelectRoom ?? (_) {},
        conversations: conversations,
        selectedId: null,
        selectedSection: null,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
      )));
    }

    FontWeight? weightOf(WidgetTester tester, String label) =>
        tester.widget<Text>(find.text(label)).style?.fontWeight;

    testWidgets('in People, bold means unread', (tester) async {
      final rows = [
        _conv(id: 'a', who: 'Unread', unread: 1),
        _conv(id: 'b', who: 'Read'),
      ];
      await pumpRail(tester, rows, rooms: peopleRooms(rows, owner: _owner));

      expect(weightOf(tester, 'Unread'), FontWeight.w600);
      expect(weightOf(tester, 'Read'), FontWeight.w500);
    });

    testWidgets('in Needs You, bold means unread as well — not "you owe it"',
        (tester) async {
      await pumpRail(tester, [
        _conv(id: 'a', who: 'Owed', state: ConversationState.needsReply),
        _conv(
          id: 'b',
          who: 'Owed and unread',
          state: ConversationState.needsReply,
          unread: 3,
        ),
      ]);

      // One grammar in the whole column. What Needs You owes is said by the
      // section badge, by the accent dot and by the ask the row is titled
      // with — never by a font weight that means something else next door.
      expect(weightOf(tester, 'Owed'), FontWeight.w500);
      expect(weightOf(tester, 'Owed and unread'), FontWeight.w600);
    });

    testWidgets('a read Needs You row still carries the accent dot',
        (tester) async {
      await pumpRail(tester, [
        _conv(id: 'a', who: 'Owed', state: ConversationState.needsReply),
      ]);

      final row =
          find.ancestor(of: find.text('Owed'), matching: find.byType(Row)).first;
      final dot = find.descendant(of: row, matching: find.byType(Container));
      final decoration =
          tester.widget<Container>(dot.first).decoration! as BoxDecoration;
      expect(decoration.color, BondColors.railAccent);
    });
  });

  group('AppRail processing grammar', () {
    final since = DateTime.utc(2026, 8, 29, 12);
    const arrivedThisSession = '2026-08-29T12:30:00Z';

    Future<void> pumpRail(
      WidgetTester tester,
      List<Conversation> conversations, {
      DateTime? processingSince,
      RailSection scope = RailSection.home,
      List<PersonRoom>? rooms,
      void Function(String)? onSelectRoom,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: rooms ?? const [],
        onSelectRoom: onSelectRoom ?? (_) {},
        conversations: conversations,
        selectedId: null,
        selectedSection: null,
        processingSince: processingSince,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
      )));
    }

    /// The 8px leading dot on the row carrying [label].
    BoxDecoration dotOf(WidgetTester tester, String label) {
      final row =
          find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
      final dot = find.descendant(of: row, matching: find.byType(Container));
      return tester.widget<Container>(dot.first).decoration! as BoxDecoration;
    }

    Color? inkOf(WidgetTester tester, String label) =>
        tester.widget<Text>(find.text(label)).style?.color;

    testWidgets('a thread the model is still reading reads quiet',
        (tester) async {
      await pumpRail(
        tester,
        [
          _conv(
            id: 'a',
            who: 'Half-read',
            state: ConversationState.needsReply,
            pending: 2,
            lastMessageAt: arrivedThisSession,
          ),
        ],
        processingSince: since,
      );

      // Needs You would normally render this loud. Whatever it says about
      // itself is a half-formed answer until the model is done.
      expect(inkOf(tester, 'Half-read'), BondColors.onDarkMuted);
      final dot = dotOf(tester, 'Half-read');
      expect(dot.color, isNull);
      expect(dot.border, isNotNull);
    });

    testWidgets('a settled thread keeps its filled dot and its ink',
        (tester) async {
      await pumpRail(
        tester,
        [
          _conv(
            id: 'a',
            who: 'Settled',
            state: ConversationState.needsReply,
            unread: 1,
            lastMessageAt: arrivedThisSession,
          ),
        ],
        processingSince: since,
      );

      expect(inkOf(tester, 'Settled'), BondColors.onDarkPrimary);
      final dot = dotOf(tester, 'Settled');
      expect(dot.color, BondColors.railAccent);
      expect(dot.border, isNull);
    });

    testWidgets('an unread thread reads quiet while the model works',
        (tester) async {
      await pumpRail(
        tester,
        [
          _conv(
            id: 'a',
            who: 'Chatty',
            state: ConversationState.needsReply,
            unread: 2,
            pending: 1,
            lastMessageAt: arrivedThisSession,
          ),
        ],
        processingSince: since,
      );

      // Unread would normally make this the loudest row on the rail. Whatever
      // it says about itself is a half-formed answer until the model is done.
      expect(inkOf(tester, 'Chatty'), BondColors.onDarkMuted);
      expect(dotOf(tester, 'Chatty').border, isNotNull);
    });

    testWidgets('the first-run backlog is not a rail full of hollow dots',
        (tester) async {
      // Every row busy, every row older than the session: the rail's own
      // caption owns that story, not two hundred outlined dots.
      await pumpRail(
        tester,
        [
          _conv(
            id: 'a',
            who: 'Backlog',
            state: ConversationState.needsReply,
            unread: 1,
            pending: 3,
            lastMessageAt: '2026-08-01T09:00:00Z',
          ),
        ],
        processingSince: since,
      );

      expect(inkOf(tester, 'Backlog'), BondColors.onDarkPrimary);
      expect(dotOf(tester, 'Backlog').border, isNull);
    });

    testWidgets('a host that never opted in shows no processing state',
        (tester) async {
      await pumpRail(tester, [
        _conv(
          id: 'a',
          who: 'Busy',
          state: ConversationState.needsReply,
          unread: 1,
          pending: 3,
          lastMessageAt: arrivedThisSession,
        ),
      ]);

      expect(inkOf(tester, 'Busy'), BondColors.onDarkPrimary);
      expect(dotOf(tester, 'Busy').border, isNull);
    });
  });

  group('AppRail People', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Conversation> conversations,
      String? selectedRoomKey,
      void Function(String)? onSelectRoom,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: RailSection.home,
        rooms: peopleRooms(conversations, owner: _owner),
        onSelectRoom: onSelectRoom ?? (_) {},
        selectedRoomKey: selectedRoomKey,
        conversations: conversations,
        selectedId: null,
        selectedSection: null,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
      )));
    }

    Conversation withPeople(
      String id, {
      String source = 'email',
      required List<Participant> people,
      ConversationState state = ConversationState.waiting,
      String? cta,
      int unread = 0,
    }) =>
        Conversation(
          id: id,
          source: source,
          participants: people,
          state: state,
          ctaText: cta,
          unreadCount: unread,
          lastMessageAt: '2026-09-01T09:00:00Z',
        );

    testWidgets('one row per person, titled by them', (tester) async {
      await pumpRail(tester, conversations: [
        withPeople('a', people: const [Participant(name: 'Eric Nolan')]),
        withPeople('b', people: const [Participant(name: 'Eric Nolan')]),
        withPeople('c', people: const [Participant(name: 'Priya Raman')]),
      ]);

      expect(find.text('Eric Nolan'), findsOneWidget);
      expect(find.text('Priya Raman'), findsOneWidget);
    });

    testWidgets('a one-source room is marked; a person on both is not',
        (tester) async {
      await pumpRail(tester, conversations: [
        withPeople(
          'chat-1',
          source: 'teams',
          people: const [Participant(name: 'Sarah Vance')],
        ),
        withPeople('a', people: const [Participant(name: 'Eric Nolan')]),
        withPeople(
          'chat-2',
          source: 'teams',
          people: const [Participant(name: 'Eric Nolan')],
        ),
      ]);

      expect(find.text('💬 Sarah Vance'), findsOneWidget);
      // Eric reaches this mailbox both ways, so neither mark would be true.
      expect(find.text('Eric Nolan'), findsOneWidget);
    });

    testWidgets('bold means the room has something unread', (tester) async {
      await pumpRail(tester, conversations: [
        withPeople(
          'a',
          people: const [Participant(name: 'Unread')],
          unread: 2,
        ),
        withPeople('b', people: const [Participant(name: 'Read')]),
      ]);

      expect(
        tester.widget<Text>(find.text('Unread')).style?.fontWeight,
        FontWeight.w600,
      );
      expect(
        tester.widget<Text>(find.text('Read')).style?.fontWeight,
        FontWeight.w500,
      );
    });

    testWidgets('the badge is the needs-you count, else the thread count',
        (tester) async {
      await pumpRail(tester, conversations: [
        withPeople(
          'a',
          people: const [Participant(name: 'Asking')],
          state: ConversationState.needsReply,
        ),
        withPeople('b', people: const [Participant(name: 'Asking')]),
        withPeople('c', people: const [Participant(name: 'Quiet')]),
        withPeople('d', people: const [Participant(name: 'Quiet')]),
      ]);

      Color fillOf(String count) {
        final pill = find
            .ancestor(of: find.text(count), matching: find.byType(Container))
            .first;
        return (tester.widget<Container>(pill).decoration! as BoxDecoration)
            .color!;
      }

      // Asking: one of two threads needs the user → a red 1, not a grey 2.
      expect(fillOf('1'), BondColors.railBadge);
      // Quiet: nothing owed, so the row says how much is there.
      expect(fillOf('2'), BondColors.onDarkTint);
    });

    testWidgets('a 1:1 room leads with a face; a group keeps the dot',
        (tester) async {
      await pumpRail(tester, conversations: [
        withPeople(
          'a',
          people: const [Participant(name: 'Eric Nolan', email: 'e@x.test')],
        ),
        withPeople('b', people: const [
          Participant(name: 'Priya Raman'),
          Participant(name: 'Tom Alder'),
        ]),
      ]);

      expect(find.byType(BondAvatar), findsOneWidget);
      expect(
        tester.widget<BondAvatar>(find.byType(BondAvatar)).name,
        'Eric Nolan',
      );
      expect(find.text('Priya Raman, Tom Alder'), findsOneWidget);
    });

    testWidgets('tapping a room reports its key', (tester) async {
      final picked = <String>[];
      await pumpRail(
        tester,
        conversations: [
          withPeople('a', people: const [Participant(name: 'Eric Nolan')]),
        ],
        onSelectRoom: picked.add,
      );

      await tester.tap(find.text('Eric Nolan'));
      expect(picked, ['eric nolan']);
    });

    testWidgets('the open room reads as selected', (tester) async {
      await pumpRail(
        tester,
        conversations: [
          withPeople('a', people: const [Participant(name: 'Eric Nolan')]),
        ],
        selectedRoomKey: 'eric nolan',
      );

      final material = find
          .ancestor(
            of: find.text('Eric Nolan'),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.widget<Material>(material).color, BondColors.onDarkTint);
    });

    testWidgets('nobody waiting says so rather than going blank',
        (tester) async {
      await pumpRail(tester, conversations: const []);

      expect(find.text('Nobody is waiting on anything'), findsOneWidget);
    });
  });

  group('AppRail scope', () {
    Future<void> pumpRail(WidgetTester tester, RailSection scope) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: peopleRooms(
          [
            Conversation(
              id: 'a',
              participants: const [Participant(name: 'Eric Nolan')],
              lastMessageAt: '2026-09-01T09:00:00Z',
            ),
          ],
          owner: _owner,
        ),
        onSelectRoom: (_) {},
        conversations: [
          _conv(id: 'n', who: 'Alice', state: ConversationState.needsReply),
        ],
        storylines: [_storyline(id: 'sl-1')],
        selectedId: null,
        selectedSection: scope,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
        onSelectStoryline: (_) {},
      )));
    }

    testWidgets('Home shows the whole stack', (tester) async {
      await pumpRail(tester, RailSection.home);

      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('STORYLINES'), findsOneWidget);
      expect(find.text('PEOPLE'), findsOneWidget);
      expect(find.text('LATER'), findsOneWidget);
    });

    testWidgets('a stop shows only its own section, and no chevron',
        (tester) async {
      await pumpRail(tester, RailSection.people);

      expect(find.text('PEOPLE'), findsOneWidget);
      expect(find.text('NEEDS YOU'), findsNothing);
      expect(find.text('STORYLINES'), findsNothing);
      expect(find.text('LATER'), findsNothing);
      // Its rows are there, and there is nothing to close them with: the user
      // picked this stop, and a chevron that emptied the column would lie.
      expect(find.text('Eric Nolan'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('every other stop narrows the same way', (tester) async {
      await pumpRail(tester, RailSection.needsYou);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('PEOPLE'), findsNothing);

      await pumpRail(tester, RailSection.storylines);
      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('NEEDS YOU'), findsNothing);

      await pumpRail(tester, RailSection.archive);
      expect(find.text('LATER'), findsOneWidget);
      expect(find.text('Nothing deferred yet'), findsOneWidget);
    });

    testWidgets('the AI stop says what its pane holds', (tester) async {
      await pumpRail(tester, RailSection.ai);

      expect(find.text('AI'), findsOneWidget);
      expect(find.text('Models, rules and the log'), findsOneWidget);
      expect(find.text('NEEDS YOU'), findsNothing);
    });

    testWidgets('Drafts & sent keeps the whole Home stack in the column',
        (tester) async {
      await pumpRail(tester, RailSection.drafts);

      // It is a ROW in the stack, not a stop, so standing on it must not empty
      // the column around it — the reader has opened one of the things that
      // stack offered, not gone somewhere else.
      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('DRAFTS & SENT'), findsOneWidget);
      expect(find.text('STORYLINES'), findsOneWidget);
      expect(find.text('PEOPLE'), findsOneWidget);
      expect(find.text('LATER'), findsOneWidget);
    });
  });

  group('storylineRows', () {
    test('puts suggestions first and keeps each half in input order', () {
      final rows = storylineRows([
        _storyline(id: 'a', status: 'active'),
        _storyline(id: 'b', status: 'suggested'),
        _storyline(id: 'c', status: 'active'),
        _storyline(id: 'd', status: 'suggested'),
      ]);

      expect(rows.map((s) => s.id), ['b', 'd', 'a', 'c']);
    });
  });

  group('AppRail storylines', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      required List<Storyline> storylines,
      List<Storyline> dismissed = const [],
      String? selectedStorylineId,
      void Function(String)? onSelectStoryline,
      void Function(String)? onKeepSuggestion,
      void Function(String)? onDismissSuggestion,
      RailSection scope = RailSection.home,
      List<PersonRoom>? rooms,
      void Function(String)? onSelectRoom,
      void Function(String)? onRestoreStoryline,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: rooms ?? const [],
        onSelectRoom: onSelectRoom ?? (_) {},
        conversations: const [],
        storylines: storylines,
        dismissed: dismissed,
        selectedId: null,
        selectedStorylineId: selectedStorylineId,
        selectedSection: RailSection.storylines,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
        onSelectStoryline: onSelectStoryline ?? (_) {},
        onKeepSuggestion: onKeepSuggestion ?? (_) {},
        onDismissSuggestion: onDismissSuggestion ?? (_) {},
        onRestoreStoryline: onRestoreStoryline ?? (_) {},
      )));
    }

    testWidgets('an empty list keeps the placeholder', (tester) async {
      await pumpRail(tester, storylines: const []);

      expect(find.text('Suggestions arrive after processing'), findsOneWidget);
    });

    testWidgets('rows replace the placeholder', (tester) async {
      await pumpRail(tester, storylines: [_storyline(id: 'sl-1')]);

      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('Suggestions arrive after processing'), findsNothing);
    });

    testWidgets('a suggestion carries Keep and Dismiss; an active row does not',
        (tester) async {
      await pumpRail(tester, storylines: [
        _storyline(id: 'sl-1', title: 'Proposed', status: 'suggested'),
        _storyline(id: 'sl-2', title: 'Live', status: 'active'),
      ]);

      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('Keep and Dismiss fire for the row they sit on',
        (tester) async {
      final kept = <String>[];
      final dismissed = <String>[];
      await pumpRail(
        tester,
        storylines: [
          _storyline(id: 'sl-1', title: 'Proposed', status: 'suggested'),
        ],
        onKeepSuggestion: kept.add,
        onDismissSuggestion: dismissed.add,
      );

      await tester.tap(find.byIcon(Icons.check));
      await tester.tap(find.byIcon(Icons.close));

      expect(kept, ['sl-1']);
      expect(dismissed, ['sl-1']);
    });

    testWidgets('an active row badges its open count, and nothing when zero',
        (tester) async {
      await pumpRail(tester, storylines: [
        _storyline(id: 'sl-1', title: 'Busy', openCount: 3),
        _storyline(id: 'sl-2', title: 'Quiet'),
      ]);

      expect(find.text('3'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('tapping a row selects that storyline', (tester) async {
      final selected = <String>[];
      await pumpRail(
        tester,
        storylines: [_storyline(id: 'sl-1')],
        onSelectStoryline: selected.add,
      );

      await tester.tap(find.text('Website redesign'));

      expect(selected, ['sl-1']);
    });

    testWidgets('an untitled storyline still renders a row', (tester) async {
      await pumpRail(tester, storylines: [_storyline(id: 'sl-1', title: '')]);

      expect(find.text('(untitled)'), findsOneWidget);
    });

    testWidgets('nothing dismissed, no fold', (tester) async {
      await pumpRail(tester, storylines: [_storyline(id: 'sl-1')]);

      expect(find.textContaining('Dismissed'), findsNothing);
    });

    testWidgets('a dismissed storyline is not one of the live rows',
        (tester) async {
      await pumpRail(
        tester,
        storylines: [_storyline(id: 'sl-1', title: 'Live', openCount: 3)],
        dismissed: [
          _storyline(id: 'sl-9', title: 'Office move', status: 'dismissed'),
        ],
      );

      await tester.tap(find.text('Dismissed · 1'));
      await tester.pumpAndSettle();

      // Open, the dismissed row is there — but it carries none of a live
      // row's grammar: no Keep/Dismiss pair, and no count pill of its own.
      expect(find.text('Office move'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.byIcon(Icons.restore), findsOneWidget);
      // The only badge on the section is the live row's open count.
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('the fold is painted with the rail\'s own fill', (tester) async {
      // The fold defaults to the ink the old rail wore; inside the burgundy
      // column it has to be told. A revert to the default would paint a dark
      // green patch in the rail with nothing else failing.
      await pumpRail(
        tester,
        storylines: const [],
        dismissed: [
          _storyline(id: 'sl-9', title: 'Office move', status: 'dismissed'),
        ],
      );

      final material = tester.widget<Material>(find
          .ancestor(
            of: find.byKey(DismissedStorylinesFold.headerKey),
            matching: find.byType(Material),
          )
          .first);
      expect(material.color, BondColors.rail);
    });
  });

  group('AppRail Drafts & sent', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      int pendingDraftCount = 0,
      RailSection? selectedSection,
      void Function(RailSection)? onSelectSection,
      RailSection scope = RailSection.home,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: scope,
        rooms: const [],
        onSelectRoom: (_) {},
        conversations: const [],
        selectedId: null,
        selectedSection: selectedSection,
        pendingDraftCount: pendingDraftCount,
        onSelectConversation: (_, _) {},
        onSelectSection: onSelectSection ?? (_) {},
      )));
    }

    testWidgets('the badge counts what is waiting, and hides at zero',
        (tester) async {
      await pumpRail(tester, pendingDraftCount: 3);
      expect(find.text('3'), findsOneWidget);

      await pumpRail(tester);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('the row has nothing under it — the pane IS the list',
        (tester) async {
      await pumpRail(tester, pendingDraftCount: 2);

      // A column that repeated the pane would be a second copy of one list,
      // one of them always a beat behind the other.
      expect(find.text('No suggested replies waiting.'), findsNothing);
    });

    testWidgets('tapping it asks for the drafts pane', (tester) async {
      final picked = <RailSection>[];
      await pumpRail(tester, onSelectSection: picked.add);

      await tester.tap(find.text('DRAFTS & SENT'));

      expect(picked, [RailSection.drafts]);
    });

    testWidgets('and it is highlighted while that pane is up', (tester) async {
      await pumpRail(
        tester,
        selectedSection: RailSection.drafts,
        scope: RailSection.drafts,
      );

      final material = tester.widget<Material>(find.ancestor(
        of: find.text('DRAFTS & SENT'),
        matching: find.byType(Material),
      ).first);
      expect(material.color, BondColors.onDarkTint);
    });
  });

  group('AppRail Find and Unread', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      String find = '',
      bool unreadOnly = false,
      List<Conversation>? conversations,
      List<Storyline>? storylines,
      List<PersonRoom>? rooms,
      List<(String, int)> laterDays = const [],
      int laterCount = 0,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: RailSection.home,
        rooms: rooms ?? const [],
        onSelectRoom: (_) {},
        conversations: conversations ?? const [],
        storylines: storylines ?? const [],
        laterDays: laterDays,
        laterCount: laterCount,
        selectedId: null,
        selectedSection: null,
        find: find,
        unreadOnly: unreadOnly,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
        onSelectStoryline: (_) {},
      )));
    }

    List<Conversation> twoAsks() => [
          _conv(
            id: 'a',
            who: 'Eric Vance',
            cta: 'Confirm the launch date',
            state: ConversationState.needsReply,
            unread: 1,
          ),
          _conv(
            id: 'b',
            who: 'Priya Raman',
            cta: 'Sign the invoice',
            state: ConversationState.needsReply,
          ),
        ];

    testWidgets('a needle narrows the rows and leaves the badge alone',
        (tester) async {
      await pumpRail(tester, conversations: twoAsks(), find: 'launch');

      expect(find.text('Confirm the launch date · Eric Vance'), findsOneWidget);
      expect(find.text('Sign the invoice · Priya Raman'), findsNothing);
      // A filter changes what you can SEE, never what you OWE. A badge that
      // shrank as the reader typed would let them hide their own work by
      // mistyping a name.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('it matches a participant nobody put in the title',
        (tester) async {
      await pumpRail(tester, conversations: twoAsks(), find: 'priya');

      expect(find.text('Sign the invoice · Priya Raman'), findsOneWidget);
      expect(find.text('Confirm the launch date · Eric Vance'), findsNothing);
    });

    testWidgets('it narrows storylines and rooms too', (tester) async {
      final rows = [
        _conv(id: 'q', who: 'Priya Raman', lastMessageAt: '2026-09-01T09:00:00Z'),
      ];
      await pumpRail(
        tester,
        conversations: rows,
        rooms: peopleRooms(rows, owner: _owner),
        storylines: [
          _storyline(id: 'sl-1', title: 'Website redesign'),
          _storyline(id: 'sl-2', title: 'Invoices'),
        ],
        find: 'redesign',
      );

      expect(find.text('Website redesign'), findsOneWidget);
      expect(find.text('Invoices'), findsNothing);
      expect(find.text('Priya Raman'), findsNothing);
    });

    testWidgets('a Later day is not findable, but the pile still says how big',
        (tester) async {
      await pumpRail(
        tester,
        laterDays: const [('2026-09-01', 3)],
        laterCount: 3,
        find: 'launch',
      );

      expect(find.text('LATER'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // No day rows, and no 'Nothing deferred yet' either: a pile being
      // filtered past must not read as an empty one.
      expect(find.textContaining('— 3'), findsNothing);
      expect(find.text('Nothing deferred yet'), findsNothing);
    });

    testWidgets('unreadOnly hides read threads and read rooms', (tester) async {
      final rows = [
        _conv(
          id: 'a',
          who: 'Eric Vance',
          cta: 'Confirm the launch date',
          state: ConversationState.needsReply,
          unread: 1,
        ),
        _conv(
          id: 'b',
          who: 'Priya Raman',
          cta: 'Sign the invoice',
          state: ConversationState.needsReply,
        ),
        _conv(id: 'q', who: 'Tom Ashby', lastMessageAt: '2026-09-01T09:00:00Z'),
      ];
      await pumpRail(
        tester,
        conversations: rows,
        rooms: peopleRooms(rows, owner: _owner),
        storylines: [_storyline(id: 'sl-1', title: 'Website redesign')],
        unreadOnly: true,
      );

      expect(find.text('Confirm the launch date · Eric Vance'), findsOneWidget);
      expect(find.text('Sign the invoice · Priya Raman'), findsNothing);
      expect(find.text('Tom Ashby'), findsNothing);
      // A storyline is not read or unread. Hiding one under a filter about
      // mail would make the toggle mean two things.
      expect(find.text('Website redesign'), findsOneWidget);
    });

    testWidgets('the first row it draws is the row firstFindTarget opens',
        (tester) async {
      final rows = twoAsks();
      await pumpRail(tester, conversations: rows, find: 'invoice');

      final target = firstFindTarget(
        scope: RailSection.home,
        conversations: rows,
        storylines: const [],
        rooms: const [],
        find: 'invoice',
        unreadOnly: false,
        threshold: 0,
      );

      // The agreement Enter's whole promise rests on: the rail draws this row
      // first, so opening the "top match" opens what is under the reader's
      // eyes. `find_filter_test` holds the other half.
      expect((target as FindThread).conversationKey, 'b');
      expect(find.text('Sign the invoice · Priya Raman'), findsOneWidget);
      expect(find.text('Confirm the launch date · Eric Vance'), findsNothing);
    });
  });

  group('AppRail on the Files stop', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      FilesKind filesKind = FilesKind.all,
      ValueChanged<FilesKind>? onSelectFilesKind,
      String find = '',
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(AppRail(
        header: const SizedBox(),
        scope: RailSection.files,
        rooms: const [],
        onSelectRoom: (_) {},
        conversations: const [],
        selectedId: null,
        selectedSection: RailSection.files,
        onSelectConversation: (_, _) {},
        onSelectSection: (_) {},
        filesKind: filesKind,
        onSelectFilesKind: onSelectFilesKind,
        find: find,
      )));
    }

    testWidgets('the column is the four shelves, and nothing else',
        (tester) async {
      await pumpRail(tester);

      for (final kind in FilesKind.values) {
        expect(
          find.byKey(ValueKey('files-kind-${kind.name}')),
          findsOneWidget,
          reason: kind.name,
        );
      }
      // No counts: a number per shelf is a fourth query for something nobody
      // acts on.
      expect(find.text('All'), findsOneWidget);
      expect(find.textContaining('All ('), findsNothing);
    });

    testWidgets('the shelf that is up is the one lit', (tester) async {
      await pumpRail(tester, filesKind: FilesKind.images);

      expect(
        tester.widget<Text>(find.text('Images')).style?.color,
        BondColors.onDarkPrimary,
      );
      expect(
        tester.widget<Text>(find.text('Links')).style?.color,
        BondColors.onDarkSecondary,
      );
    });

    testWidgets('picking one tells the host which', (tester) async {
      final picked = <FilesKind>[];
      await pumpRail(tester, onSelectFilesKind: picked.add);

      await tester.tap(find.byKey(const ValueKey('files-kind-links')));
      await tester.pump();

      expect(picked, [FilesKind.links]);
    });

    testWidgets('Find leaves the shelves alone', (tester) async {
      // There is nothing here to narrow, and a row that vanished while the
      // reader typed a colleague's name would take the way into a shelf with
      // it — the drafts section's rule.
      await pumpRail(tester, find: 'invoice');

      for (final kind in FilesKind.values) {
        expect(
          find.byKey(ValueKey('files-kind-${kind.name}')),
          findsOneWidget,
          reason: kind.name,
        );
      }
    });
  });
}
