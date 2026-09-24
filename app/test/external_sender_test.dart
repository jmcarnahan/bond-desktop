import 'package:bond_inbox/services/external_sender.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether a sender is from outside the owner's own organisation, as arithmetic
/// on two strings. No database, no account and no network: the whole value of
/// this pair is that it can be read on every message in a verdict path.
///
/// Every domain below is fictional. The owner works at `northwind.example.com`
/// throughout, which is what makes the subdomain and suffix cases readable.

void main() {
  group('ownerDomainsOf', () {
    test('the domain of the signed-in address', () {
      expect(
        ownerDomainsOf('dana@northwind.example.com'),
        {'northwind.example.com'},
      );
    });

    test('case and surrounding space are folded away', () {
      // The address arrives from Entra, where nothing promises either.
      expect(
        ownerDomainsOf('  Dana.Okafor@Northwind.Example.COM '),
        {'northwind.example.com'},
      );
    });

    test('the LAST at-sign is the one that counts', () {
      // A quoted local part may contain one. The domain is what follows the
      // final separator, which is the rule every mail system uses.
      expect(
        ownerDomainsOf('"dana@home"@northwind.example.com'),
        {'northwind.example.com'},
      );
    });

    test('nothing to read is the empty set', () {
      // Which [isExternalAddress] answers false to — no account means no
      // strangers, the reading that changes nothing.
      expect(ownerDomainsOf(null), isEmpty);
      expect(ownerDomainsOf(''), isEmpty);
      expect(ownerDomainsOf('   '), isEmpty);
      expect(ownerDomainsOf('dana'), isEmpty);
      expect(ownerDomainsOf('dana@'), isEmpty);
    });
  });

  group('isExternalAddress', () {
    const owned = {'northwind.example.com'};

    test('a colleague is not external', () {
      expect(isExternalAddress('sam@northwind.example.com', owned), isFalse);
    });

    test('a stranger is', () {
      expect(isExternalAddress('sales@vendor.example.net', owned), isTrue);
    });

    test('case and space do not decide it', () {
      expect(isExternalAddress(' SAM@Northwind.Example.com ', owned), isFalse);
      expect(isExternalAddress(' SALES@Vendor.Example.net ', owned), isTrue);
    });

    test('a subdomain of an owner domain is inside', () {
      // One organisation, several mail hosts: a notification from
      // `alerts.northwind…` is the owner's own tooling, not a cold approach.
      expect(
        isExternalAddress('alerts@mail.northwind.example.com', owned),
        isFalse,
      );
    });

    test('a domain that merely ENDS with one is outside', () {
      // The dot in the suffix check is what makes this a domain test rather
      // than a string test. `notnorthwind.example.com` is somebody else.
      expect(
        isExternalAddress('hi@notnorthwind.example.com', owned),
        isTrue,
      );
    });

    test('any owner domain matching is enough', () {
      // The set is where an owner-managed list would arrive; two domains read
      // as one organisation today.
      const two = {'northwind.example.com', 'northwind-legal.example.org'};
      expect(isExternalAddress('counsel@northwind-legal.example.org', two),
          isFalse);
      expect(isExternalAddress('sales@vendor.example.net', two), isTrue);
    });

    test('an address with no at-sign is never external', () {
      // The case this rule exists for: a Teams sender is `teams:<guid>`, which
      // names no domain at all. Reading it as external would make every chat a
      // stranger's approach, and the needs-you floor is Teams-only.
      expect(isExternalAddress('teams:19:a1b2c3', owned), isFalse);
      expect(isExternalAddress('dana', owned), isFalse);
    });

    test('nothing to read is never external', () {
      expect(isExternalAddress(null, owned), isFalse);
      expect(isExternalAddress('', owned), isFalse);
      expect(isExternalAddress('   ', owned), isFalse);
      expect(isExternalAddress('sales@', owned), isFalse);
    });

    test('no owner domains means the question cannot be asked', () {
      // An account that has not arrived yet. False, not true: an unknown must
      // never round up into taking a message off the rail.
      expect(isExternalAddress('sales@vendor.example.net', const {}), isFalse);
    });

    test('an empty string in the owner set is ignored, not matched', () {
      // A half-written preference must not make every sender internal.
      expect(
        isExternalAddress('sales@vendor.example.net', const {''}),
        isTrue,
      );
    });
  });
}
