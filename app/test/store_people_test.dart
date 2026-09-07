import 'dart:convert';

import 'package:bond_inbox/data/database.dart' show BondDatabase;
import 'package:bond_inbox/data/message_store.dart';
import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/models/person.dart';
import 'package:bond_inbox/services/chat_roster.dart';
import 'package:bond_inbox/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/test_db.dart';

/// Who the recipients field can offer without asking anybody: the people
/// already in this database.
///
/// Two sources feed it and neither is enough alone — inbound messages know who
/// WROTE, conversation rosters know who was on a thread — so most of this file
/// is about the merge between them: one person per address, the newest
/// sighting winning, and a Teams id decoded into somebody a chat can be opened
/// with.

void main() {
  late BondDatabase db;
  late MessageStore store;

  setUp(() {
    db = testDb();
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  /// One mail row, built the way the sync builds every one of its own.
  Map<String, Object?> mail({
    required String id,
    String direction = 'inbound',
    String? fromName = 'Sarah Whitfield',
    String? fromAddress = 'sarah@x.com',
    String conversationKey = 'conv-1',
    String receivedAt = '2026-09-01T12:00:00Z',
  }) =>
      SyncService.mailRow(
        id: id,
        conversationKey: conversationKey,
        direction: direction,
        fromName: fromName,
        fromAddress: fromAddress,
        to: const ['me@x.com'],
        receivedAt: receivedAt,
        isRead: true,
        triageStatus: 'skipped',
        gateReason: 'outbound',
      );

  Map<String, Object?> chatRow({
    required String id,
    String? fromName = 'Ravi Patel',
    String? fromAddress = 'teams:u-ravi',
    String conversationKey = 'chat-1',
    String receivedAt = '2026-09-02T12:00:00Z',
  }) =>
      {
        'source': 'teams',
        'source_message_id': id,
        'conversation_key': conversationKey,
        'direction': 'inbound',
        'from_name': fromName,
        'from_address': fromAddress,
        'received_at': receivedAt,
        'is_read': 1,
        'triage_status': 'skipped',
        'gate_reason': 'teams-bot',
      };

  Future<void> conversation({
    required String source,
    required String key,
    String? subject,
    List<Map<String, String?>> participants = const [],
    String? lastMessageAt,
  }) =>
      store.upsertConversation({
        'source': source,
        'conversation_key': key,
        'subject': subject,
        'participants_json': jsonEncode(participants),
        'state': 'waiting',
        'last_message_at': lastMessageAt,
      });

  group('recentPeople from messages', () {
    test('offers whoever wrote, newest first', () async {
      await store.upsertMessage(mail(
        id: 'm1',
        fromName: 'Sarah Whitfield',
        fromAddress: 'sarah@x.com',
        receivedAt: '2026-09-01T12:00:00Z',
      ));
      await store.upsertMessage(mail(
        id: 'm2',
        fromName: 'Ravi Patel',
        fromAddress: 'ravi@x.com',
        receivedAt: '2026-09-03T12:00:00Z',
      ));

      final people = await store.recentPeople();

      expect([for (final p in people) p.displayName],
          ['Ravi Patel', 'Sarah Whitfield']);
      expect(people.first.mail, 'ravi@x.com');
      expect(people.first.source, PersonSource.recent);
      // No Graph id behind a mail row, which is exactly what stops the Teams
      // half of compose from offering them.
      expect(people.first.hasGraphId, isFalse);
    });

    test('counts one person once, however many messages they sent', () async {
      await store.upsertMessage(mail(id: 'm1', receivedAt: '2026-09-01T12:00:00Z'));
      await store.upsertMessage(mail(
        id: 'm2',
        fromAddress: 'SARAH@x.com',
        receivedAt: '2026-09-04T12:00:00Z',
      ));

      final people = await store.recentPeople();

      expect(people, hasLength(1));
      expect(people.single.id, 'mail:sarah@x.com');
    });

    test('ignores the user\'s own outbound mail', () async {
      // An outbound row's `from_address` is the user. Offering it back would
      // put them in their own recipients list.
      await store.upsertMessage(mail(
        id: 'm1',
        direction: 'outbound',
        fromName: 'Jordan Bond',
        fromAddress: 'me@x.com',
      ));

      expect(await store.recentPeople(), isEmpty);
    });

    test('decodes a Teams sender into somebody a chat can be opened with',
        () async {
      await store.upsertMessage(chatRow(id: 't1'));

      final people = await store.recentPeople();

      expect(people.single.id, 'u-ravi');
      expect(people.single.hasGraphId, isTrue);
      expect(people.single.teamsAddress, 'teams:u-ravi');
      expect(people.single.mail, isNull);
    });

    test('but drops a Teams id with no name beside it', () async {
      // An id alone renders as an empty chip and matches no query.
      await store.upsertMessage(chatRow(id: 't1', fromName: ''));

      expect(await store.recentPeople(), isEmpty);
    });
  });

  group('recentPeople from conversation rosters', () {
    test('offers people who were on a thread but never wrote', () async {
      // The only place a mail recipient the user never heard back from
      // appears at all.
      await conversation(
        source: 'email',
        key: 'conv-1',
        participants: const [
          {'name': 'Dana Cho', 'email': 'dana@x.com'},
        ],
        lastMessageAt: '2026-09-05T12:00:00Z',
      );

      final people = await store.recentPeople();

      expect(people.single.displayName, 'Dana Cho');
      expect(people.single.mail, 'dana@x.com');
    });

    test('and Teams members, with their ids intact', () async {
      await conversation(
        source: 'teams',
        key: 'chat-1',
        participants: const [
          {'name': 'Ravi Patel', 'email': 'teams:u-ravi'},
        ],
        lastMessageAt: '2026-09-05T12:00:00Z',
      );

      expect((await store.recentPeople()).single.id, 'u-ravi');
    });

    test('merges with the message half on the address, keeping the newest',
        () async {
      // The same person from both halves is one entry, ranked by the later of
      // the two sightings.
      await store.upsertMessage(mail(id: 'm1', receivedAt: '2026-09-01T12:00:00Z'));
      await conversation(
        source: 'email',
        key: 'conv-1',
        participants: const [
          {'name': 'Sarah W.', 'email': 'Sarah@X.com'},
        ],
        lastMessageAt: '2026-09-09T12:00:00Z',
      );
      await store.upsertMessage(mail(
        id: 'm2',
        fromName: 'Ravi Patel',
        fromAddress: 'ravi@x.com',
        receivedAt: '2026-09-05T12:00:00Z',
      ));

      final people = await store.recentPeople();

      expect(people, hasLength(2));
      // Sarah's roster sighting is newer than Ravi's message, so she leads.
      expect([for (final p in people) p.id],
          ['mail:sarah@x.com', 'mail:ravi@x.com']);
      expect(people.first.displayName, 'Sarah W.');
    });

    test('a newer nameless sighting keeps the name an older one had',
        () async {
      // The sync stores a mail recipient as a bare address, so a thread the
      // user replied to last carries Sarah without her name — and she must
      // not lose it just because that thread is the newest.
      await store.upsertMessage(mail(id: 'm1', receivedAt: '2026-09-01T12:00:00Z'));
      await conversation(
        source: 'email',
        key: 'conv-1',
        participants: const [
          {'name': null, 'email': 'sarah@x.com'},
        ],
        lastMessageAt: '2026-09-09T12:00:00Z',
      );

      final people = await store.recentPeople();

      expect(people.single.displayName, 'Sarah Whitfield');
    });

    test('a roster entry with no address is not a person', () async {
      await conversation(
        source: 'email',
        key: 'conv-1',
        participants: const [
          {'name': 'Nobody', 'email': null},
        ],
        lastMessageAt: '2026-09-05T12:00:00Z',
      );

      expect(await store.recentPeople(), isEmpty);
    });
  });

  group('recentPeople filtering', () {
    setUp(() async {
      await store.upsertMessage(mail(
        id: 'm1',
        fromName: 'Sarah Whitfield',
        fromAddress: 'sarah@x.com',
        receivedAt: '2026-09-01T12:00:00Z',
      ));
      await store.upsertMessage(mail(
        id: 'm2',
        fromName: 'Ravi Patel',
        fromAddress: 'ravi.patel@x.com',
        receivedAt: '2026-09-02T12:00:00Z',
      ));
      await store.upsertMessage(chatRow(id: 't1', receivedAt: '2026-09-03T12:00:00Z'));
    });

    test('matches a prefix of any word of the name', () async {
      // Not a substring: typing `wh` must find Sarah Whitfield without
      // dragging in everyone with an `h` in their surname.
      expect([for (final p in await store.recentPeople(query: 'wh')) p.id],
          ['mail:sarah@x.com']);
      expect(await store.recentPeople(query: 'hit'), isEmpty);
    });

    test('and a prefix of the address', () async {
      expect(
        [for (final p in await store.recentPeople(query: 'ravi.pat')) p.id],
        ['mail:ravi.patel@x.com'],
      );
    });

    test('a blank query offers everybody', () async {
      expect(await store.recentPeople(), hasLength(3));
    });

    test('the source restricts both halves', () async {
      final mailOnly = await store.recentPeople(source: 'email');
      final teamsOnly = await store.recentPeople(source: 'teams');

      expect([for (final p in mailOnly) p.id],
          ['mail:ravi.patel@x.com', 'mail:sarah@x.com']);
      expect([for (final p in teamsOnly) p.id], ['u-ravi']);
    });

    test('and the limit is the number of people, not of rows read', () async {
      final people = await store.recentPeople(limit: 2);

      // Newest two: the chat message, then Ravi's mail.
      expect([for (final p in people) p.id], ['u-ravi', 'mail:ravi.patel@x.com']);
    });
  });

  group('teamsChats', () {
    setUp(() async {
      await conversation(
        source: 'teams',
        key: 'chat-1',
        subject: 'Contract review',
        participants: const [
          {'name': 'Ravi Patel', 'email': 'teams:u-ravi'},
        ],
        lastMessageAt: '2026-09-01T12:00:00Z',
      );
      await conversation(
        source: 'teams',
        key: 'chat-2',
        subject: 'Sarah Whitfield',
        participants: const [
          {'name': 'Sarah Whitfield', 'email': 'teams:u-sarah'},
        ],
        lastMessageAt: '2026-09-05T12:00:00Z',
      );
      await conversation(
        source: 'email',
        key: 'conv-1',
        subject: 'Contract review',
        lastMessageAt: '2026-09-09T12:00:00Z',
      );
    });

    test('lists Teams threads only, newest activity first', () async {
      final chats = await store.teamsChats();

      expect([for (final c in chats) c.id], ['chat-2', 'chat-1']);
    });

    test('matches a subject anywhere in it', () async {
      // A chat is recognised by any word of a topic somebody else wrote, not
      // by how that topic starts.
      expect([for (final c in await store.teamsChats(query: 'review')) c.id],
          ['chat-1']);
    });

    test('and a participant name', () async {
      expect([for (final c in await store.teamsChats(query: 'whitf')) c.id],
          ['chat-2']);
    });

    test('but never a Graph id that happens to contain the letters', () async {
      // The reason the filter is in Dart: a LIKE over `participants_json`
      // would match the address half as readily as the name half.
      expect(await store.teamsChats(query: 'u-sar'), isEmpty);
    });
  });

  group('rosterMatch', () {
    Conversation chat(List<String> ids, {String source = 'teams'}) =>
        Conversation(
          id: 'chat-1',
          source: source,
          participants: [
            for (final id in ids) Participant(name: id, email: 'teams:$id'),
          ],
        );

    test('the same people are the same chat', () {
      expect(rosterMatch(chat(['u1', 'u2']), {'u2', 'u1'}), RosterMatch.exact);
    });

    test('one more or one fewer is a different chat', () {
      expect(rosterMatch(chat(['u1', 'u2']), {'u1'}), RosterMatch.different);
      expect(
        rosterMatch(chat(['u1', 'u2']), {'u1', 'u2', 'u3'}),
        RosterMatch.different,
      );
      expect(rosterMatch(chat(['u1']), {'u9'}), RosterMatch.different);
    });

    test('a roster at the cap the picked set covers is UNKNOWN, not a match',
        () {
      // `TeamsSync` stores at most eight members, so a row with eight may be a
      // chat with twelve. Calling that exact would post into a thread holding
      // people the user never picked.
      final full = [for (var i = 0; i < teamsRosterCap; i++) 'u$i'];

      expect(
        rosterMatch(chat(full), {...full, 'u99'}),
        RosterMatch.unknown,
      );
      // Covered exactly is still exact: the sizes agree.
      expect(rosterMatch(chat(full), full.toSet()), RosterMatch.exact);
      // Not covered is simply different, cap or no cap.
      expect(
        rosterMatch(chat(full), {...full.take(3), 'u99'}),
        RosterMatch.different,
      );
    });

    test('a mail thread is never a chat, whatever it holds', () {
      expect(rosterMatch(chat(['u1'], source: 'email'), {'u1'}),
          RosterMatch.different);
    });

    test('teamsMemberIds skips anything that is not a Teams address', () {
      const mixed = Conversation(
        id: 'chat-1',
        source: 'teams',
        participants: [
          Participant(name: 'Ravi', email: 'teams:u-ravi'),
          Participant(name: 'Sarah', email: 'sarah@x.com'),
          Participant(name: 'Blank', email: 'teams:'),
          Participant(name: 'None'),
        ],
      );

      expect(teamsMemberIds(mixed), {'u-ravi'});
    });
  });

  group('matchesPersonQuery', () {
    const sarah = Person(
      id: 'u1',
      displayName: 'Sarah Whitfield',
      mail: 'sarah.w@x.com',
      userPrincipalName: 'swhitfield@x.onmicrosoft.com',
    );

    test('matches any word of the name, from its front', () {
      expect(matchesPersonQuery(sarah, 'sar'), isTrue);
      expect(matchesPersonQuery(sarah, 'WHIT'), isTrue);
      expect(matchesPersonQuery(sarah, 'hitfield'), isFalse);
    });

    test('a second word narrows rather than empties', () {
      // Typing a first name and then a surname is how most people reach for
      // somebody; the second word must keep matching, in either order.
      expect(matchesPersonQuery(sarah, 'sarah wh'), isTrue);
      expect(matchesPersonQuery(sarah, 'wh sa'), isTrue);
      expect(matchesPersonQuery(sarah, 'sarah ortiz'), isFalse);
    });

    test('matches the address and the sign-in name too', () {
      expect(matchesPersonQuery(sarah, 'sarah.w@'), isTrue);
      expect(matchesPersonQuery(sarah, 'swhit'), isTrue);
    });

    test('and a blank query matches everybody', () {
      expect(matchesPersonQuery(sarah, ''), isTrue);
      expect(matchesPersonQuery(sarah, '   '), isTrue);
    });

    test('somebody with no name and no address matches only a blank query', () {
      const nobody = Person(id: 'u9', displayName: '');

      expect(matchesPersonQuery(nobody, ''), isTrue);
      expect(matchesPersonQuery(nobody, 'a'), isFalse);
    });
  });
}
