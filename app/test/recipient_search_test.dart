import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/providers/recipient_search_provider.dart';
import 'package:bond_inbox/services/backend/auth_session.dart';
import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/backend/people_backend.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// The one read behind every keystroke in the recipients field.
///
/// What is pinned here is mostly what does NOT happen: no directory request
/// without the grant, none once the server has said the scope is missing, and
/// no exception out of [RecipientSearch.search] whatever the backend does —
/// the field calls it from an `optionsBuilder` the SDK runs unawaited, where a
/// throw takes the frame down over a list of names.

/// A directory that answers from a script and counts what it was asked.
class _FakePeople implements PeopleBackend {
  final List<Person> people;
  Object? error;
  final List<String> queries = [];

  _FakePeople({this.people = const [], this.error});

  @override
  Future<List<Person>> searchPeople(String query, {int top = 10}) async {
    queries.add(query);
    final thrown = error;
    if (thrown != null) throw thrown;
    return people;
  }

  @override
  Future<ProfilePhoto?> profilePhoto(String user, {String size = '96x96'}) async =>
      null;
}

/// A session granting exactly what it was built with.
class _FakeAuth implements AuthSession {
  final Set<String> scopes;
  final AccountInfo? account;
  final Object? scopeError;

  _FakeAuth({this.scopes = const {}, this.account, this.scopeError});

  @override
  Future<bool> hasScope(String bareScope) async {
    final thrown = scopeError;
    if (thrown != null) throw thrown;
    return scopes.contains(bareScope);
  }

  @override
  Future<AccountInfo?> get storedAccount async => account;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const String _directoryScope = 'user.readbasic.all';

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  Future<void> mailFrom(
    String name,
    String address, {
    String at = '2026-09-01T12:00:00Z',
    String id = 'm1',
  }) =>
      store.upsertMessage(SyncService.mailRow(
        id: id,
        conversationKey: 'conv-$id',
        direction: 'inbound',
        fromName: name,
        fromAddress: address,
        to: const ['me@x.com'],
        receivedAt: at,
        isRead: true,
        triageStatus: 'skipped',
        gateReason: 'outbound',
      ));

  Future<void> chatWith(
    String name,
    String userId, {
    String key = 'chat-1',
    String subject = 'Ravi Patel',
    String at = '2026-09-01T12:00:00Z',
  }) =>
      store.upsertConversation({
        'source': 'teams',
        'conversation_key': key,
        'subject': subject,
        'participants_json': jsonEncode([
          {'name': name, 'email': 'teams:$userId'},
        ]),
        'state': 'waiting',
        'last_message_at': at,
      });

  RecipientSearch searchWith({
    _FakePeople? people,
    _FakeAuth? auth,
    Future<String?> Function()? myUserId,
    DateTime Function()? clock,
  }) =>
      RecipientSearch(
        people ?? _FakePeople(),
        store,
        auth ?? _FakeAuth(scopes: const {_directoryScope}),
        myUserId ?? () async => null,
        clock: clock,
      );

  group('the scope gate', () {
    test('without the grant the directory is never asked', () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com');
      final people = _FakePeople();

      final results = await searchWith(
        people: people,
        auth: _FakeAuth(),
      ).search('sar', channel: RecipientChannel.mail);

      expect(people.queries, isEmpty);
      expect(results.scopeMissing, isTrue);
      // And the field still has something to show.
      expect([for (final p in results.recents) p.mail], ['sarah@x.com']);
    });

    test('with the grant it is asked, and both lists come back', () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com');
      final people = _FakePeople(people: const [
        Person(id: 'u2', displayName: 'Ravi Patel', mail: 'ravi@x.com'),
      ]);

      final results = await searchWith(people: people)
          .search('sar', channel: RecipientChannel.mail);

      expect(people.queries, ['sar']);
      expect([for (final p in results.recents) p.mail], ['sarah@x.com']);
      expect([for (final p in results.directory) p.mail], ['ravi@x.com']);
      expect(results.scopeMissing, isFalse);
      expect(results.directoryOffline, isFalse);
    });

    test('a blank query reads the grant but asks nothing', () async {
      // The footer says the same thing on an empty field as on a full one,
      // and there is nothing to look up for a query nobody typed.
      final people = _FakePeople();

      final results = await searchWith(people: people)
          .search('  ', channel: RecipientChannel.mail);

      expect(people.queries, isEmpty);
      expect(results.scopeMissing, isFalse);
    });

    test('a grant that cannot be read is not a grant', () async {
      final people = _FakePeople();

      final results = await searchWith(
        people: people,
        auth: _FakeAuth(scopeError: StateError('no connection')),
      ).search('sar', channel: RecipientChannel.mail);

      expect(people.queries, isEmpty);
      expect(results.scopeMissing, isTrue);
    });

    test('a server that says the scope is missing is not asked again',
        () async {
      // Sticky for the session: the answer cannot change until somebody
      // consents and the app reconnects, and asking would cost a request per
      // keystroke to be refused every time.
      final people = _FakePeople(
        error: const DirectoryUnavailable(
          scopeMissing: true,
          message: 'no directory',
        ),
      );
      final search = searchWith(people: people);

      final first = await search.search('sar', channel: RecipientChannel.mail);
      final second = await search.search('rav', channel: RecipientChannel.mail);

      expect(people.queries, ['sar']);
      expect(first.scopeMissing, isTrue);
      expect(second.scopeMissing, isTrue);
      expect(search.scopeMissing, isTrue);
    });

    test('but the verdict expires, so a consent lands without a restart',
        () async {
      // A reconnect after the admin consents runs through the same session
      // and rebuilds nothing under this provider. Believing the refusal for
      // ever would leave the directory dark until the app was relaunched.
      var now = DateTime.utc(2026, 9, 6, 12);
      final people = _FakePeople(
        error: const DirectoryUnavailable(
          scopeMissing: true,
          message: 'no directory',
        ),
      );
      final search = searchWith(people: people, clock: () => now);

      await search.search('sar', channel: RecipientChannel.mail);
      now = now.add(RecipientSearch.scopeMissingTtl - const Duration(seconds: 1));
      await search.search('sar', channel: RecipientChannel.mail);
      expect(people.queries, ['sar'], reason: 'still believed');

      people.error = null;
      now = now.add(const Duration(seconds: 2));
      final results = await search.search('sar', channel: RecipientChannel.mail);

      expect(people.queries, ['sar', 'sar']);
      expect(results.scopeMissing, isFalse);
    });

    test('and a reconnect can take that back', () async {
      final people = _FakePeople(
        error: const DirectoryUnavailable(
          scopeMissing: true,
          message: 'no directory',
        ),
      );
      final search = searchWith(people: people);

      await search.search('sar', channel: RecipientChannel.mail);
      people.error = null;
      search.resetScope();
      await search.search('sar', channel: RecipientChannel.mail);

      expect(people.queries, ['sar', 'sar']);
      expect(search.scopeMissing, isFalse);
    });
  });

  group('failures never reach the field', () {
    test('a transient directory failure degrades to recents', () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com');
      final people = _FakePeople(
        error: const DirectoryUnavailable(
          scopeMissing: false,
          message: 'throttled',
        ),
      );
      final search = searchWith(people: people);

      final results = await search.search('sar', channel: RecipientChannel.mail);

      expect(results.directoryOffline, isTrue);
      expect(results.directory, isEmpty);
      expect(results.recents, hasLength(1));
      // Not sticky: the next keystroke tries again.
      expect(search.scopeMissing, isFalse);
      await search.search('sar', channel: RecipientChannel.mail);
      expect(people.queries, hasLength(2));
    });

    test('an auth failure is swallowed too, rather than routed from here',
        () async {
      // Routing to sign-in out of a typeahead would throw away everything the
      // user had typed. It belongs to whatever they do next.
      final results = await searchWith(
        people: _FakePeople(error: const ReconsentRequired()),
      ).search('sar', channel: RecipientChannel.mail);

      expect(results.directoryOffline, isTrue);
    });

    test('and so is anything else the backend can throw', () async {
      final results = await searchWith(
        people: _FakePeople(error: StateError('boom')),
      ).search('sar', channel: RecipientChannel.mail);

      expect(results.directoryOffline, isTrue);
      expect(results.directory, isEmpty);
    });

    test('a profile lookup that fails costs nothing but the id filter',
        () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com');

      final results = await searchWith(
        myUserId: () async => throw StateError('no Teams here'),
      ).search('sar', channel: RecipientChannel.mail);

      expect(results.recents, hasLength(1));
    });
  });

  group('the merge', () {
    test('a directory hit replaces the recent naming the same address',
        () async {
      // Both are the same person, and only the directory one carries the Graph
      // id that can open a chat.
      await mailFrom('Sarah W.', 'Sarah@X.com');
      final people = _FakePeople(people: const [
        Person(id: 'u1', displayName: 'Sarah Whitfield', mail: 'sarah@x.com'),
      ]);

      final results = await searchWith(people: people)
          .search('sar', channel: RecipientChannel.mail);

      expect(results.recents, isEmpty);
      expect(results.directory.single.id, 'u1');
    });

    test('and the recent carrying the same Graph id, which has no address',
        () async {
      // A Teams recent is an id and a name, nothing else; the address key is
      // empty, so the id is the only way to see it is the directory's person.
      await chatWith('Ravi P', 'u-ravi');
      final people = _FakePeople(people: const [
        Person(id: 'u-ravi', displayName: 'Ravi Patel', jobTitle: 'Counsel'),
      ]);

      final results = await searchWith(people: people)
          .search('rav', channel: RecipientChannel.teams);

      expect(results.recents, isEmpty);
      expect(results.directory.single.jobTitle, 'Counsel');
    });

    test('and leaves the rest of the recents where they were', () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com',
          id: 'm1', at: '2026-09-01T12:00:00Z');
      await mailFrom('Sam Ortiz', 'sam@x.com',
          id: 'm2', at: '2026-09-03T12:00:00Z');
      final people = _FakePeople(people: const [
        Person(id: 'u1', displayName: 'Sarah Whitfield', mail: 'sarah@x.com'),
      ]);

      final results = await searchWith(people: people)
          .search('sa', channel: RecipientChannel.mail);

      expect([for (final p in results.recents) p.mail], ['sam@x.com']);
    });

    test('the user is dropped by address', () async {
      await mailFrom('Jordan Bond', 'me@x.com');
      final people = _FakePeople(people: const [
        Person(id: 'u-me', displayName: 'Jordan Bond', mail: 'ME@x.com'),
        Person(id: 'u1', displayName: 'Sarah', mail: 'sarah@x.com'),
      ]);

      final results = await searchWith(
        people: people,
        auth: _FakeAuth(
          scopes: const {_directoryScope},
          account: const AccountInfo(displayName: 'Jordan', mail: 'me@x.com'),
        ),
      ).search('a', channel: RecipientChannel.mail);

      expect(results.recents, isEmpty);
      expect([for (final p in results.directory) p.id], ['u1']);
    });

    test('and by id, for an account whose mail says nothing', () async {
      final people = _FakePeople(people: const [
        Person(id: 'u-me', displayName: 'Jordan Bond'),
        Person(id: 'u1', displayName: 'Sarah'),
      ]);

      final results = await searchWith(
        people: people,
        myUserId: () async => 'u-me',
      ).search('a', channel: RecipientChannel.mail);

      expect([for (final p in results.directory) p.id], ['u1']);
    });

    test('the profile is asked for once, however many keystrokes', () async {
      var calls = 0;
      final search = searchWith(myUserId: () async {
        calls++;
        return 'u-me';
      });

      await search.search('a', channel: RecipientChannel.mail);
      await search.search('ab', channel: RecipientChannel.mail);

      expect(calls, 1);
    });
  });

  group('the two channels', () {
    test('mail offers mail recents and no chats', () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com');
      await chatWith('Ravi Patel', 'u-ravi');

      final results =
          await searchWith().search('', channel: RecipientChannel.mail);

      expect([for (final p in results.recents) p.mail], ['sarah@x.com']);
      expect(results.chats, isEmpty);
    });

    test('teams offers chat people and the chats themselves', () async {
      await mailFrom('Sarah Whitfield', 'sarah@x.com');
      await chatWith('Ravi Patel', 'u-ravi');

      final results =
          await searchWith().search('', channel: RecipientChannel.teams);

      expect([for (final p in results.recents) p.id], ['u-ravi']);
      expect([for (final c in results.chats) c.id], ['chat-1']);
    });

    test('and never somebody with no Graph id to chat with', () async {
      // A roster entry stored without an id is a name with nothing behind it;
      // `ensureChat` would fail at the server.
      await store.upsertConversation({
        'source': 'teams',
        'conversation_key': 'chat-2',
        'subject': 'Odd one',
        'participants_json': jsonEncode([
          {'name': 'Mailed In', 'email': 'guest@x.com'},
        ]),
        'state': 'waiting',
        'last_message_at': '2026-09-02T12:00:00Z',
      });

      final results =
          await searchWith().search('', channel: RecipientChannel.teams);

      expect(results.recents, isEmpty);
      expect(results.chats, hasLength(1));
    });
  });
}
