import 'package:bond_inbox/models/files_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/storyline_models.dart';
import 'package:bond_inbox/services/profile_photos.dart';
import 'package:bond_inbox/widgets/person_panel.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';

/// Who a person is, beside whatever they turned up in.
///
/// Nothing here is stored — a person is derived from the live inbox — so what
/// the panel owes the reader is honesty about which state each list is in:
/// still reading, genuinely empty, or an answer.
Conversation _thread(
  String id, {
  String source = 'email',
  String? subject,
  String who = 'Dana Whitfield',
  String? address = 'dana@example.test',
}) =>
    Conversation(
      id: id,
      source: source,
      subject: subject,
      participants: [Participant(name: who, email: address)],
      lastMessageAt: '2026-09-08T09:00:00Z',
    );

PersonRoom _room({
  List<Conversation>? threads,
  List<Participant>? people,
  int needsYou = 0,
  String? latestAt = '2026-09-08T09:00:00Z',
}) =>
    PersonRoom(
      key: 'dana whitfield',
      title: 'Dana Whitfield',
      threads: threads ?? [_thread('c1', subject: 'Homepage copy')],
      unread: 0,
      needsYou: needsYou,
      sources: {for (final t in threads ?? const <Conversation>[]) t.source},
      latestAt: latestAt,
      people: people ??
          const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
          ],
    );

FileRow _file(String id) => FileRow(
      ref: ref(attachmentId: id, name: '$id.pdf'),
      fromName: 'Dana Whitfield',
      fromAddress: 'dana@example.test',
      receivedAt: '2026-09-04T10:00:00Z',
      subject: 'The lease',
    );

void main() {
  final now = DateTime(2026, 9, 8, 12);

  Future<void> pump(
    WidgetTester tester, {
    PersonRoom? room,
    List<Storyline> storylines = const [],
    List<FileRow> files = const [],
    bool loaded = true,
    void Function(String, String)? onOpenThread,
    void Function(String)? onOpenStoryline,
    void Function(FileRow)? onOpenFile,
  }) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PersonPanelBody(
          room: room,
          storylines: storylines,
          files: files,
          loaded: loaded,
          now: now,
          photos: const NoProfilePhotos(),
          onOpenThread: onOpenThread ?? (_, _) {},
          onOpenStoryline: onOpenStoryline ?? (_) {},
          onOpenFile: onOpenFile ?? (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('a person with nothing live says exactly that', (tester) async {
    // Rooms ARE the live inbox. A person whose only thread is deferred or done
    // has no room, and the honest answer is that nothing is going on.
    await pump(tester, room: null);

    expect(
      find.text('Nothing live with this person right now.'),
      findsOneWidget,
    );
    expect(find.text('THREADS'), findsNothing);
  });

  group('who they are', () {
    testWidgets('name and a writable address', (tester) async {
      await pump(tester, room: _room());

      expect(find.text('Dana Whitfield'), findsOneWidget);
      expect(find.text('dana@example.test'), findsOneWidget);
    });

    testWidgets('a teams id is not an address and is not shown',
        (tester) async {
      // It is a Graph id, it means nothing to a reader, and nobody can write
      // to it.
      await pump(
        tester,
        room: _room(
          people: const [
            Participant(name: 'Dana Whitfield', email: 'teams:19:abc'),
          ],
        ),
      );

      expect(find.text('Dana Whitfield'), findsOneWidget);
      expect(find.textContaining('teams:'), findsNothing);
    });

    testWidgets('the counts split by connector, zeroes left out',
        (tester) async {
      await pump(
        tester,
        room: _room(threads: [
          _thread('c1', subject: 'One'),
          _thread('c2', subject: 'Two'),
          _thread('chat-1', source: 'teams'),
        ]),
      );

      expect(find.text('3 threads · 2 mail · 1 chat'), findsOneWidget);
    });

    testWidgets('a mail-only person has no chat half', (tester) async {
      await pump(tester, room: _room(threads: [_thread('c1')]));
      expect(find.text('1 thread · 1 mail'), findsOneWidget);
    });

    testWidgets('the needs-you count rides along when there is one',
        (tester) async {
      await pump(
        tester,
        room: _room(threads: [_thread('c1')], needsYou: 1),
      );

      expect(find.text('1 thread · 1 mail · 1 need you'), findsOneWidget);
    });

    testWidgets('last seen, when anything is stamped', (tester) async {
      await pump(tester, room: _room());
      expect(find.textContaining('Last seen '), findsOneWidget);

      await pump(tester, room: _room(latestAt: null));
      expect(find.textContaining('Last seen '), findsNothing);
    });
  });

  group('the lists', () {
    testWidgets('storylines are named and open', (tester) async {
      final opened = <String>[];
      await pump(
        tester,
        room: _room(),
        storylines: const [
          Storyline(id: 'sl-1', title: 'Website redesign', status: 'active'),
        ],
        onOpenStoryline: opened.add,
      );

      expect(find.text('# Website redesign'), findsOneWidget);
      await tester.tap(find.byKey(PersonPanelBody.storylineKeyFor('sl-1')));
      await tester.pump();
      expect(opened, ['sl-1']);
    });

    testWidgets('a person in none says so', (tester) async {
      await pump(tester, room: _room());
      expect(find.text('In no storyline.'), findsOneWidget);
    });

    testWidgets('threads carry their source mark and open', (tester) async {
      final opened = <(String, String)>[];
      await pump(
        tester,
        room: _room(threads: [
          _thread('c1', subject: 'Homepage copy'),
          _thread('chat-1', source: 'teams', subject: 'Launch date'),
        ]),
        onOpenThread: (source, key) => opened.add((source, key)),
      );

      expect(find.text('Homepage copy'), findsOneWidget);
      expect(find.text('💬 Launch date'), findsOneWidget);

      await tester
          .tap(find.byKey(PersonPanelBody.threadKeyFor('teams', 'chat-1')));
      await tester.pump();
      expect(opened, [('teams', 'chat-1')]);
    });

    testWidgets('files they sent are cards, and they open', (tester) async {
      final opened = <String>[];
      final row = _file('a');
      await pump(
        tester,
        room: _room(),
        files: [row],
        onOpenFile: (r) => opened.add(r.ref.attachmentId),
      );

      await tester.tap(find.byKey(PersonPanelBody.fileKeyFor(row)));
      await tester.pump();
      expect(opened, ['a']);
    });

    testWidgets('a person who has sent nothing says so', (tester) async {
      await pump(tester, room: _room());
      expect(find.text('No files from them.'), findsOneWidget);
    });

    testWidgets('while the read is out, the derived lists say so',
        (tester) async {
      // An empty list drawn as empty space reads as a bug — and "nothing" is a
      // different answer from "not yet".
      await pump(tester, room: _room(), loaded: false);

      expect(find.text('Loading…'), findsNWidgets(2));
      expect(find.text('In no storyline.'), findsNothing);
      expect(find.text('No files from them.'), findsNothing);
      // The threads come off the room itself, so they are never pending.
      expect(find.text('Homepage copy'), findsOneWidget);
    });
  });
}
