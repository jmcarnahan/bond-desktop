import 'dart:convert';

import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/graph_people.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The directory read, with only the socket faked.
///
/// Most of this file is about the URL, for graph_teams_test.dart's reason
/// turned up a notch: Graph refuses `$search` on `/users` OUTRIGHT without
/// `ConsistencyLevel: eventual` and `$count=true`, and accepts a mis-quoted
/// search expression while returning the wrong people. A test that only asked
/// "did we get a list" would pass against both.
///
/// The stubs are duplicated from the other Graph tests rather than shared, so
/// neither file can break the other by editing it.
class _Tokens implements TokenStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> deleteAll() async => values.clear();
}

const String _grantedScopes =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read '
    'https://graph.microsoft.com/User.ReadBasic.All';

/// One request as the stub saw it.
class _Sent {
  final Uri url;
  final Map<String, String> headers;

  _Sent(this.url, this.headers);
}

void main() {
  late List<_Sent> seen;

  setUp(() => seen = []);

  /// A directory whose `/users` call is answered by [respond].
  GraphPeople peopleWith(http.Response Function() respond) {
    final tokens = _Tokens();
    tokens.values['refresh_token'] = 'rt';
    tokens.values['granted_scopes'] = _grantedScopes;

    final client = MockClient((request) async {
      if (request.url.host == 'login.microsoftonline.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'at-1',
            'refresh_token': 'rt-1',
            'expires_in': 3600,
            'scope': _grantedScopes,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      seen.add(_Sent(request.url, request.headers));
      return respond();
    });

    return GraphPeople(
      GraphAuth(httpClient: client, store: tokens),
      httpClient: client,
    );
  }

  http.Response jsonOk(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );

  group('the search URL', () {
    test('asks /users with everything Graph requires of a \$search', () async {
      await peopleWith(() => jsonOk({'value': const []})).searchPeople('jo');

      final request = seen.single;
      expect(request.url.path, '/v1.0/users');
      final query = request.url.queryParameters;
      // Decoded, because the quoting is what matters and the encoding of it is
      // not: a `$search` whose quotes were mangled returns the wrong people
      // with a perfectly happy 200.
      expect(query[r'$search'], '"displayName:jo" OR "mail:jo"');
      expect(query[r'$select'],
          'id,displayName,mail,userPrincipalName,jobTitle');
      expect(query[r'$top'], '10');
      // Both are Graph's price for a $search on /users, not options.
      expect(query[r'$count'], 'true');
      expect(query[r'$orderby'], 'displayName');
      expect(request.headers['ConsistencyLevel'], 'eventual');
      expect(request.headers['Authorization'], 'Bearer at-1');
    });

    test('spaces travel as %20, never as +', () async {
      // Graph's OData parser reads a `+` as a plus sign, so a search for two
      // words would look for one word with punctuation in the middle.
      await peopleWith(() => jsonOk({'value': const []}))
          .searchPeople('sarah whitfield');

      expect(seen.single.url.query, contains('%20'));
      expect(seen.single.url.query, isNot(contains('+')));
    });

    test('carries the caller\'s cap, clamped to what Graph accepts', () async {
      await peopleWith(() => jsonOk({'value': const []}))
          .searchPeople('jo', top: 500);

      expect(seen.single.url.queryParameters[r'$top'], '50');
    });

    test('strips what would break the expression, and keeps the words apart',
        () async {
      // A quote would close the search string; `&`, `#` and `%` are query-string
      // punctuation a hand-built URL must not carry raw. Each becomes a SPACE,
      // so two words somebody ran together stay two words.
      await peopleWith(() => jsonOk({'value': const []}))
          .searchPeople('  "sar"ah&whit#field%  ');

      expect(seen.single.url.queryParameters[r'$search'],
          '"displayName:sar ah whit field" OR "mail:sar ah whit field"');
    });

    test('a query that sanitises to nothing makes no request', () async {
      final people = peopleWith(() => jsonOk({'value': const []}));

      expect(await people.searchPeople('   '), isEmpty);
      expect(await people.searchPeople('"" & ##'), isEmpty);
      expect(seen, isEmpty);
    });
  });

  group('the results', () {
    test('map Graph\'s camelCase onto the same model the MCP twin produces',
        () async {
      final people = await peopleWith(
        () => jsonOk({
          'value': [
            {
              'id': 'u1',
              'displayName': 'Sarah Whitfield',
              'mail': 'sarah@x.com',
              'userPrincipalName': 'sarah@x.onmicrosoft.com',
              'jobTitle': 'General Counsel',
            },
            {
              'id': 'u2',
              'displayName': 'Ravi Patel',
              'mail': null,
              'userPrincipalName': 'ravi@x.onmicrosoft.com',
            },
          ],
        }),
      ).searchPeople('a');

      expect([for (final p in people) p.id], ['u1', 'u2']);
      expect(people.first.jobTitle, 'General Counsel');
      expect(people.first.address, 'sarah@x.com');
      expect(people.last.mail, isNull);
      expect(people.last.address, 'ravi@x.onmicrosoft.com');
      expect(people.first.hasGraphId, isTrue);
    });

    test('drop an entry with no id, which nothing could be sent to', () async {
      final people = await peopleWith(
        () => jsonOk({
          'value': [
            {'displayName': 'No id'},
            {'id': '', 'displayName': 'Empty id'},
            {'id': 'u3', 'displayName': 'Ravi'},
          ],
        }),
      ).searchPeople('a');

      expect([for (final p in people) p.id], ['u3']);
    });

    test('a body that is not a directory answer is no people, not a crash',
        () async {
      expect(await peopleWith(() => jsonOk({'value': 'nope'})).searchPeople('a'),
          isEmpty);
    });
  });

  group('failures', () {
    test('a 403 is the tenant refusing the scope, and is permanent', () async {
      await expectLater(
        peopleWith(() => jsonOk({'error': 'forbidden'}, 403)).searchPeople('a'),
        throwsA(isA<DirectoryUnavailable>()
            .having((e) => e.scopeMissing, 'scopeMissing', isTrue)),
      );
    });

    test('anything else is a bad moment worth another keystroke', () async {
      await expectLater(
        peopleWith(() => jsonOk({'error': 'boom'}, 500)).searchPeople('a'),
        throwsA(isA<DirectoryUnavailable>()
            .having((e) => e.scopeMissing, 'scopeMissing', isFalse)
            .having((e) => e.message, 'message', contains('500'))),
      );
    });

    test('a 401 is retried once, like every other Graph call', () async {
      var calls = 0;
      final people = peopleWith(() {
        calls++;
        return calls == 1
            ? jsonOk({'error': 'expired'}, 401)
            : jsonOk({
                'value': [
                  {'id': 'u1', 'displayName': 'Sarah'},
                ],
              });
      });

      expect((await people.searchPeople('a')).single.id, 'u1');
      expect(seen, hasLength(2));
    });
  });
}
