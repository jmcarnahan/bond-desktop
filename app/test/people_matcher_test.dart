import 'package:bond_inbox/models/message_models.dart';
import 'package:bond_inbox/services/calendar/calendar_zone.dart';
import 'package:bond_inbox/services/calendar/command/command_types.dart';
import 'package:bond_inbox/services/calendar/command/people_matcher.dart';
import 'package:bond_inbox/services/calendar/when_resolver.dart';
import 'package:bond_inbox/widgets/people_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who a command names, looked up in the People directory. Fictional people.
void main() {
  const dana = KnownPerson(
      name: 'Dana Whitfield', address: 'dana@contoso.com', roomKey: 'r-dana');
  const danaK =
      KnownPerson(name: 'Dana Kim', address: 'dkim@fabrikam.com', roomKey: 'r-dk');
  const lee = KnownPerson(name: 'Lee Park', address: 'lee@fabrikam.com');
  const may = KnownPerson(name: 'May Chen', address: 'may@contoso.com');
  const people = [dana, danaK, lee, may];

  group('hits', () {
    test('a full name, any case, even with a namesake in the directory', () {
      final m = matchPeople('book a sync with dana whitfield', people);
      expect(m.matched, [dana]);
      expect(m.ambiguous, isEmpty);
      final (s, e) = m.spans.single;
      expect('book a sync with dana whitfield'.substring(s, e),
          'dana whitfield');
    });

    test('a unique first name', () {
      final m = matchPeople('lunch with Lee on Friday', people);
      expect(m.matched, [lee]);
      expect(m.unresolved, isEmpty);
    });

    test('a first name several people share is ambiguous', () {
      final m = matchPeople('move my 1:1 with Dana', people);
      expect(m.matched, isEmpty);
      expect(m.ambiguous, [
        [dana, danaK],
      ]);
    });

    test('an address, known or not', () {
      final m = matchPeople(
          'invite lee@fabrikam.com and sam@contoso.com', people);
      expect(m.matched, [
        lee,
        const KnownPerson(name: '', address: 'sam@contoso.com'),
      ]);
    });

    test('a possessive is the person', () {
      final m = matchPeople("accept Lee's invite", people);
      expect(m.matched, [lee]);
    });

    test('a list of people', () {
      final m = matchPeople('find time with Lee, May Chen and Priya', people);
      expect(m.matched, [lee, may]);
      expect(m.unresolved, ['Priya']);
    });
  });

  group('not people', () {
    test('an unknown capitalised name after "with" is unresolved', () {
      final m = matchPeople('book a review with Priya Shah', people);
      expect(m.matched, isEmpty);
      expect(m.unresolved, ['Priya Shah']);
    });

    test('a capitalised subject word is not a person', () {
      final m = matchPeople('book Design review with Lee', people);
      expect(m.matched, [lee]);
      expect(m.unresolved, isEmpty);
    });

    test('a weekday is not a person, even after "with"', () {
      final m = matchPeople('sync with Friday', people);
      expect(m.unresolved, isEmpty);
    });

    test('the first word of a sentence is not a person', () {
      // "Priya" opens the text; "Sam" follows a cue mid-sentence.
      final m = matchPeople('Priya wants a sync. Invite Sam', people);
      expect(m.unresolved, ['Sam']);
    });

    test('consumed spans (a when-phrase) are never people', () async {
      await initCalendarZones();
      const text = 'book lunch with May 3';
      final w = resolveWhen(text,
          now: DateTime.utc(2026, 4, 1, 17),
          zone: CalendarZone.utc(),
          mode: WhenMode.booking);
      final m = matchPeople(text, people,
          consumed: {for (final s in w.spans) (s.start, s.end)});
      expect(m.matched, isEmpty);
      expect(m.unresolved, isEmpty);
    });

    test('a lower-case everyday word that is also a first name is not', () {
      final m = matchPeople('you may cancel the sync', people);
      expect(m.matched, isEmpty);
      // Capitalised, it is.
      expect(matchPeople('cancel the sync with May', people).matched, [may]);
    });
  });

  group('knownPeopleFrom', () {
    test('one per address, best name, Teams-only people skipped', () {
      final known = knownPeopleFrom([
        (
          key: 'r1',
          people: const [
            Participant(name: 'Dana', email: 'Dana@Contoso.com'),
            Participant(name: 'Chat only', email: 'teams:29:abc'),
            Participant(name: 'No address'),
          ],
        ),
        (
          key: 'r2',
          people: const [
            Participant(name: 'Dana Whitfield', email: 'dana@contoso.com'),
            Participant(name: 'lee@fabrikam.com', email: 'lee@fabrikam.com'),
          ],
        ),
      ]);
      expect(known, [
        const KnownPerson(
            name: 'Dana Whitfield', address: 'dana@contoso.com', roomKey: 'r1'),
        const KnownPerson(name: '', address: 'lee@fabrikam.com', roomKey: 'r2'),
      ]);
    });

    test('the room adapter reads PersonRoom', () {
      final known = knownPeopleOfRooms([
        const PersonRoom(
          key: 'teams:29:abc',
          title: 'Chat only',
          threads: [],
          unread: 0,
          needsYou: 0,
          sources: {'teams'},
          latestAt: null,
          people: [Participant(name: 'Chat only', email: 'teams:29:abc')],
        ),
        const PersonRoom(
          key: 'lee@fabrikam.com',
          title: 'Lee Park',
          threads: [],
          unread: 0,
          needsYou: 0,
          sources: {'mail'},
          latestAt: null,
          people: [Participant(name: 'Lee Park', email: 'lee@fabrikam.com')],
        ),
      ]);
      expect(known, [
        const KnownPerson(
            name: 'Lee Park',
            address: 'lee@fabrikam.com',
            roomKey: 'lee@fabrikam.com'),
      ]);
    });
  });
}
