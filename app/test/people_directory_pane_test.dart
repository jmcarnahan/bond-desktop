import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/people_sort.dart';
import 'package:bond_inbox/services/profile_photos.dart';
import 'package:bond_inbox/widgets/people_directory_pane.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everyone the mailbox knows, one row each.
///
/// The claim is that a PERSON is the unit: one row per colleague saying how
/// much of the mailbox they are, ordered and narrowed by controls the reader
/// owns. Its predecessor was a flat list of threads, which put the same person
/// on the screen twice and said nothing about them.

Conversation _thread(
  String id, {
  String source = 'email',
  String? at = '2026-09-04T10:00:00Z',
}) =>
    Conversation(
      id: id,
      source: source,
      participants: const [
        Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
      ],
      lastMessageAt: at,
    );

PersonRoom _room(
  String key, {
  String? title,
  int unread = 0,
  int needsYou = 0,
  List<Conversation>? threads,
  String? latestAt = '2026-09-04T10:00:00Z',
  String address = 'dana@example.test',
}) {
  final rows = threads ?? [_thread('$key-c1')];
  return PersonRoom(
    key: key,
    title: title ?? key,
    threads: rows,
    unread: unread,
    needsYou: needsYou,
    sources: {for (final t in rows) t.source},
    latestAt: latestAt,
    people: key == noSenderRoom
        ? const []
        : [Participant(name: title ?? key, email: address)],
  );
}

void main() {
  final now = DateTime(2026, 9, 8, 12);

  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<List<String>> pump(
    WidgetTester tester, {
    required List<PersonRoom> rooms,
    PeopleFilter filter = PeopleFilter.all,
    PeopleSort sort = PeopleSort.recent,
    String needle = '',
    Widget? emptyNotice,
    void Function(PeopleFilter)? onFilter,
    void Function(PeopleSort)? onSort,
    void Function(String)? onSearch,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PeopleDirectoryPane(
          rooms: rooms,
          filter: filter,
          onFilter: onFilter ?? (_) {},
          sort: sort,
          onSort: onSort ?? (_) {},
          searchController: controller,
          onSearch: onSearch ?? (_) {},
          needle: needle,
          now: now,
          photos: const NoProfilePhotos(),
          onOpen: opened.add,
          emptyNotice: emptyNotice,
        ),
      ),
    ));
    await tester.pump();
    return opened;
  }

  double topOf(WidgetTester tester, String key) =>
      tester.getTopLeft(find.byKey(PeopleDirectoryPane.rowKeyFor(key))).dy;

  testWidgets('the rows arrive in the order the host handed them',
      (tester) async {
    await pump(tester, rooms: [
      _room('dana', title: 'Dana Whitfield'),
      _room('eric', title: 'Eric Nolan'),
      _room('priya', title: 'Priya Raman'),
    ]);

    expect(find.text('Dana Whitfield'), findsOneWidget);
    expect(topOf(tester, 'dana'), lessThan(topOf(tester, 'eric')));
    expect(topOf(tester, 'eric'), lessThan(topOf(tester, 'priya')));
  });

  testWidgets('the caption counts the threads, the mail and the chats',
      (tester) async {
    await pump(tester, rooms: [
      _room('dana', title: 'Dana Whitfield', needsYou: 2, threads: [
        _thread('c1'),
        _thread('c2'),
        _thread('chat-1', source: 'teams'),
      ]),
    ]);

    expect(find.text('3 threads · 2 mail · 1 chat · 2 need you'),
        findsOneWidget);
  });

  testWidgets('and counts in the singular, leaving the zero half out',
      (tester) async {
    await pump(tester, rooms: [
      _room('dana', title: 'Dana Whitfield', threads: [_thread('c1')]),
    ]);

    expect(find.text('1 thread · 1 mail'), findsOneWidget);
  });

  testWidgets('the filter field narrows by name', (tester) async {
    final typed = <String>[];
    await pump(
      tester,
      rooms: [
        _room('dana', title: 'Dana Whitfield'),
        _room('eric', title: 'Eric Nolan'),
      ],
      onSearch: typed.add,
    );

    await tester.enterText(find.byType(TextField), 'nolan');
    await tester.pump();

    expect(typed, ['nolan']);

    // The host normalises and hands the needle back, which is what narrows.
    await pump(
      tester,
      rooms: [
        _room('dana', title: 'Dana Whitfield'),
        _room('eric', title: 'Eric Nolan'),
      ],
      needle: 'nolan',
    );

    expect(find.byKey(PeopleDirectoryPane.rowKeyFor('eric')), findsOneWidget);
    expect(find.byKey(PeopleDirectoryPane.rowKeyFor('dana')), findsNothing);
  });

  testWidgets('Needs you and Unread keep only the rooms that qualify',
      (tester) async {
    final rooms = [
      _room('dana', title: 'Dana Whitfield', unread: 3, needsYou: 1),
      _room('eric', title: 'Eric Nolan', unread: 2),
      _room('priya', title: 'Priya Raman'),
    ];

    await pump(tester, rooms: rooms, filter: PeopleFilter.needsYou);
    expect(find.byKey(PeopleDirectoryPane.rowKeyFor('dana')), findsOneWidget);
    expect(find.byKey(PeopleDirectoryPane.rowKeyFor('eric')), findsNothing);

    await pump(tester, rooms: rooms, filter: PeopleFilter.unread);
    expect(find.byKey(PeopleDirectoryPane.rowKeyFor('eric')), findsOneWidget);
    expect(find.byKey(PeopleDirectoryPane.rowKeyFor('priya')), findsNothing);
  });

  testWidgets('a pill reports the filter the reader picked', (tester) async {
    final picked = <PeopleFilter>[];
    await pump(
      tester,
      rooms: [_room('dana', title: 'Dana Whitfield')],
      onFilter: picked.add,
    );

    await tester.tap(find.descendant(
      of: find.byKey(PeopleDirectoryPane.filterPillsKey),
      matching: find.text(PeopleFilter.unread.label),
    ));
    await tester.pump();

    expect(picked, [PeopleFilter.unread]);
  });

  testWidgets('By name orders them, and the no-sender room sorts last',
      (tester) async {
    await pump(
      tester,
      rooms: [
        _room(noSenderRoom, title: noSenderRoom),
        _room('zoe', title: 'Zoe Kerr'),
        _room('ada', title: 'Ada Sun'),
      ],
      sort: PeopleSort.name,
    );

    expect(topOf(tester, 'ada'), lessThan(topOf(tester, 'zoe')));
    expect(topOf(tester, 'zoe'), lessThan(topOf(tester, noSenderRoom)));
  });

  testWidgets('Needs you first floats the rooms that are owed something',
      (tester) async {
    await pump(
      tester,
      rooms: [
        _room('quiet', title: 'Quiet Colleague'),
        _room('dana', title: 'Dana Whitfield', needsYou: 2),
      ],
      sort: PeopleSort.needsYou,
    );

    expect(topOf(tester, 'dana'), lessThan(topOf(tester, 'quiet')));
  });

  testWidgets('the sort menu reports the order the reader picked',
      (tester) async {
    final picked = <PeopleSort>[];
    await pump(
      tester,
      rooms: [_room('dana', title: 'Dana Whitfield')],
      onSort: picked.add,
    );

    await tester.tap(find.byKey(PeopleDirectoryPane.sortKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.byKey(PeopleDirectoryPane.sortItemKeyFor(PeopleSort.name)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(picked, [PeopleSort.name]);
  });

  testWidgets('a row tap names the person it stands for', (tester) async {
    final opened = await pump(tester, rooms: [
      _room('dana', title: 'Dana Whitfield'),
      _room('eric', title: 'Eric Nolan'),
    ]);

    await tester.tap(find.byKey(PeopleDirectoryPane.rowKeyFor('eric')));
    await tester.pump();

    expect(opened, ['eric']);
  });

  testWidgets('an empty directory and a narrowed one say different things',
      (tester) async {
    await pump(tester, rooms: const []);
    expect(find.byKey(PeopleDirectoryPane.emptyKey), findsOneWidget);
    expect(find.text('Nobody here yet.'), findsOneWidget);

    await pump(
      tester,
      rooms: [_room('dana', title: 'Dana Whitfield')],
      needle: 'zzz',
    );
    expect(find.text('Nobody matches.'), findsOneWidget);
    expect(find.text('Nobody here yet.'), findsNothing);
  });

  testWidgets('the host\'s scope notice sits under the empty line',
      (tester) async {
    await pump(
      tester,
      rooms: const [],
      emptyNotice: const Text('Showing Teams only.'),
    );

    expect(find.text('Nobody here yet.'), findsOneWidget);
    expect(find.text('Showing Teams only.'), findsOneWidget);
  });
}
