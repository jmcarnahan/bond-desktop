import 'package:bond_inbox/models/person.dart';
import 'package:flutter_test/flutter_test.dart';

/// The recipient model, and the three questions everything above it asks: is
/// this the same person, can they be mailed, and can a Teams chat be opened
/// with them.

void main() {
  group('identity', () {
    test('two people with the same id are the same person', () {
      const a = Person(id: 'u1', displayName: 'Sarah Whitfield');
      const b = Person(
        id: 'u1',
        displayName: 'S. Whitfield',
        jobTitle: 'Counsel',
        source: PersonSource.recent,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('and two with different ids are not, however alike they read', () {
      const a = Person(id: 'u1', displayName: 'Sarah Whitfield');
      const b = Person(id: 'u2', displayName: 'Sarah Whitfield');

      expect(a, isNot(b));
    });

    test('a typed address is one person however it was capitalised', () {
      // The chip list dedupes on `==`, so `Foo@X.com` typed after `foo@x.com`
      // must not become a second chip for the same mailbox.
      expect(Person.typed('Foo@X.com'), Person.typed('foo@x.com'));
      expect(Person.typed('  foo@x.com  ').id, 'mail:foo@x.com');
    });

    test('and it keeps the address as typed for display', () {
      final person = Person.typed('  Foo@X.com ');

      expect(person.displayName, 'Foo@X.com');
      expect(person.mail, 'Foo@X.com');
      expect(person.source, PersonSource.typed);
    });
  });

  group('addresses', () {
    test('the mailbox wins, then the sign-in name, then nothing', () {
      const both = Person(
        id: 'u1',
        displayName: 'Sarah',
        mail: 'sarah@x.com',
        userPrincipalName: 'sarah@x.onmicrosoft.com',
      );
      const upnOnly = Person(
        id: 'u2',
        displayName: 'Ravi',
        userPrincipalName: 'ravi@x.onmicrosoft.com',
      );
      const neither = Person(id: 'u3', displayName: 'Nobody');

      expect(both.address, 'sarah@x.com');
      expect(upnOnly.address, 'ravi@x.onmicrosoft.com');
      expect(neither.address, '');
      expect(neither.addressKey, '');
    });

    test('the dedupe key is the address, lowercased', () {
      const person = Person(id: 'u1', displayName: 'S', mail: 'Sarah@X.com');

      expect(person.addressKey, 'sarah@x.com');
    });
  });

  group('Teams reachability', () {
    test('a Graph id can open a chat and spells itself the way rows do', () {
      const person = Person(id: 'u1', displayName: 'Sarah');

      expect(person.hasGraphId, isTrue);
      expect(person.teamsAddress, 'teams:u1');
    });

    test('an address-derived id cannot', () {
      // This is the whole reason the prefix exists: a recent built out of a
      // mail row has no Microsoft identity behind it, and asking Graph to
      // start a chat with `mail:sarah@x.com` would fail at the server.
      final person = Person.typed('sarah@x.com');

      expect(person.hasGraphId, isFalse);
      expect(person.teamsAddress, isNull);
    });

    test('and neither can a person with no id at all', () {
      const person = Person(id: '', displayName: 'Sarah');

      expect(person.hasGraphId, isFalse);
      expect(person.teamsAddress, isNull);
    });
  });

  group('the directory wire', () {
    test('maps every snake_case key', () {
      final person = Person.fromDirectoryJson(const {
        'id': 'u1',
        'display_name': 'Sarah Whitfield',
        'mail': 'sarah@x.com',
        'user_principal_name': 'sarah@x.onmicrosoft.com',
        'job_title': 'General Counsel',
      });

      expect(person.id, 'u1');
      expect(person.displayName, 'Sarah Whitfield');
      expect(person.mail, 'sarah@x.com');
      expect(person.userPrincipalName, 'sarah@x.onmicrosoft.com');
      expect(person.jobTitle, 'General Counsel');
      expect(person.source, PersonSource.directory);
    });

    test('reads an empty string as absent', () {
      // A mailbox-less account and one with an empty mail string are the same
      // person to everything downstream, and `address` must fall through to
      // the sign-in name for both.
      final person = Person.fromDirectoryJson(const {
        'id': 'u1',
        'display_name': 'Ravi',
        'mail': '',
        'user_principal_name': 'ravi@x.onmicrosoft.com',
      });

      expect(person.mail, isNull);
      expect(person.address, 'ravi@x.onmicrosoft.com');
    });

    test('tolerates a payload with nothing in it', () {
      final person = Person.fromDirectoryJson(const {});

      expect(person.id, '');
      expect(person.displayName, '');
      expect(person.address, '');
    });
  });

  group('isValidEmailAddress', () {
    test('accepts what a mail server would', () {
      for (final address in [
        'sarah@x.com',
        'sarah.whitfield@sub.example.co.uk',
        'sarah+contracts@x.com',
        "o'brien@x.com",
        '  sarah@x.com  ',
      ]) {
        expect(isValidEmailAddress(address), isTrue, reason: address);
      }
    });

    test('refuses what would only become a chip nobody can send to', () {
      for (final address in [
        '',
        '   ',
        'sarah',
        'sarah@',
        '@x.com',
        'sarah@x',
        'sarah@x.',
        'sarah@.com',
        'sarah@@x.com',
        'sarah whitfield@x.com',
        'sarah@x.com extra',
      ]) {
        expect(isValidEmailAddress(address), isFalse, reason: '"$address"');
      }
    });
  });
}
