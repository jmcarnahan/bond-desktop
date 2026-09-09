import 'dart:async';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/files_models.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/providers/person_facts_provider.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/attachment_refs.dart';
import 'fixtures/test_db.dart';

/// What the Person panel knows beyond the room itself.
///
/// Two claims. The files are narrowed by SENDER, and by either half of a
/// person's identity — mail knows an address, a Teams roster knows a name, and
/// the same colleague reaches this mailbox both ways. And the seq guard: a
/// read started for one person must write nothing once the reader has moved to
/// another.

/// A store whose file read the test drives by hand.
class _SlowStore extends MessageStore {
  final List<Completer<List<FileRow>>> pending = [];

  _SlowStore(super.db);

  /// Answered without touching sqlite, so the order two concurrent loads reach
  /// the file read in is the order they were started in and nothing else.
  @override
  Future<List<String>> storylineIdsFor(String source, String conversationKey) =>
      Future.value(const []);

  @override
  Future<List<FileRow>> recentAttachments({
    List<String> sources = const ['email', 'teams'],
    FilesKind kind = FilesKind.all,
    int limit = 100,
    int offset = 0,
  }) {
    final completer = Completer<List<FileRow>>();
    pending.add(completer);
    return completer.future;
  }
}

Conversation _thread(String id, {String source = 'email'}) => Conversation(
      id: id,
      source: source,
      subject: id,
      lastMessageAt: '2026-09-08T09:00:00Z',
    );

PersonRoom _room(
  String key, {
  List<Conversation>? threads,
  List<Participant>? people,
}) =>
    PersonRoom(
      key: key,
      title: key,
      threads: threads ?? [_thread('c1')],
      unread: 0,
      needsYou: 0,
      sources: const {'email'},
      latestAt: '2026-09-08T09:00:00Z',
      people: people ??
          const [
            Participant(name: 'Dana Whitfield', email: 'dana@example.test'),
          ],
    );

FileRow _file(
  String id, {
  String? fromAddress = 'dana@example.test',
  String? fromName = 'Dana Whitfield',
  bool outbound = false,
}) =>
    FileRow(
      ref: ref(attachmentId: id, name: '$id.pdf'),
      fromAddress: fromAddress,
      fromName: fromName,
      outbound: outbound,
      receivedAt: '2026-09-04T10:00:00Z',
      subject: 'The lease',
    );

/// Waits until [count] file reads are in flight. The load reads storylines
/// first, so the completer this test drives does not exist on the frame the
/// future was created.
Future<void> _untilAsked(_SlowStore store, int count) async {
  for (var i = 0; i < 100 && store.pending.length < count; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late BondDatabase db;

  setUp(() {
    db = testDb();
  });

  tearDown(() => db.close());

  const sources = ['email', 'teams'];

  group('storylines', () {
    test('deduped, in the order they were first seen', () async {
      final store = MessageStore(db);
      for (final id in ['sl-1', 'sl-2']) {
        await store.insertStoryline(
          id: id,
          title: id,
          status: 'active',
          createdBy: 'auto',
        );
      }
      // Two threads, both in sl-1; the second also in sl-2.
      await store.addStorylineMember('sl-1', 'email', 'c1', addedBy: 'auto');
      await store.addStorylineMember('sl-1', 'email', 'c2', addedBy: 'auto');
      await store.addStorylineMember('sl-2', 'email', 'c2', addedBy: 'auto');

      final facts = PersonFactsNotifier(store);
      await facts.load(
        _room('dana', threads: [_thread('c1'), _thread('c2')]),
        sources: sources,
      );

      expect(facts.state.storylineIds, ['sl-1', 'sl-2']);
      expect(facts.state.loaded, isTrue);
      expect(facts.state.roomKey, 'dana');
    });
  });

  group('files', () {
    Future<PersonFactsState> loadWith(
      List<FileRow> rows, {
      PersonRoom? room,
    }) async {
      final store = _SlowStore(db);
      final facts = PersonFactsNotifier(store);
      final load = facts.load(room ?? _room('dana'), sources: sources);
      await _untilAsked(store, 1);
      store.pending.single.complete(rows);
      await load;
      return facts.state;
    }

    test('kept when the address matches', () async {
      final state = await loadWith([
        _file('a'),
        _file('b', fromAddress: 'someone@else.test', fromName: 'Someone Else'),
      ]);

      expect(state.files.map((f) => f.ref.attachmentId), ['a']);
    });

    test('kept when only the NAME matches, which is all Teams gives',
        () async {
      final state = await loadWith([
        _file('a', fromAddress: 'teams:19:abc'),
      ]);

      expect(state.files.map((f) => f.ref.attachmentId), ['a']);
    });

    test('the reader\'s own outbound files are not theirs', () async {
      final state = await loadWith([_file('a', outbound: true)]);
      expect(state.files, isEmpty);
    });

    test('a person who has sent nothing gets an empty list that has loaded',
        () async {
      final state = await loadWith(const []);
      expect(state.files, isEmpty);
      expect(state.loaded, isTrue);
    });
  });

  test('a slow answer for one person never overwrites a fast one for another',
      () async {
    final store = _SlowStore(db);
    final facts = PersonFactsNotifier(store);

    final first = facts.load(_room('dana'), sources: sources);
    final second = facts.load(
      _room(
        'eric',
        people: const [
          Participant(name: 'Eric Vance', email: 'eric@example.test'),
        ],
      ),
      sources: sources,
    );

    await _untilAsked(store, 2);
    // The SECOND person is the one on screen, so their answer wins whichever
    // order the two land in.
    store.pending[1].complete([_file('eric-a', fromAddress: 'eric@example.test',
        fromName: 'Eric Vance')]);
    await second;
    store.pending[0].complete([_file('dana-a')]);
    await first;

    expect(facts.state.roomKey, 'eric');
    expect(facts.state.files.map((f) => f.ref.attachmentId), ['eric-a']);
  });

  test('a read that fails keeps the panel honest rather than blank', () async {
    final store = _FailingStore(db);
    final facts = PersonFactsNotifier(store);

    await facts.load(_room('dana'), sources: sources);

    expect(facts.state.loaded, isTrue);
    expect(facts.state.error, isNotNull);
  });
}

/// A store whose file read throws.
class _FailingStore extends MessageStore {
  _FailingStore(super.db);

  @override
  Future<List<FileRow>> recentAttachments({
    List<String> sources = const ['email', 'teams'],
    FilesKind kind = FilesKind.all,
    int limit = 100,
    int offset = 0,
  }) =>
      Future.error(StateError('no'));
}
