import 'dart:convert';

import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The scope half of [GraphAuth]: which scopes are required, which are merely
/// asked for, what a grant is read as satisfying, and the one retry a refused
/// consent is allowed.
///
/// The store stub is deliberately duplicated from auth_refresh_test rather than
/// shared, so neither file can break the other by editing it.
class InMemoryTokenStore implements TokenStore {
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

/// What Entra returns for a grant of the core scopes: resource-qualified,
/// case-folded, and with no `offline_access`.
const String coreGrant =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

/// The same, plus everything the extended round asks for.
const String fullGrant = '$coreGrant '
    'https://graph.microsoft.com/Mail.ReadWrite '
    'https://graph.microsoft.com/Mail.Send '
    'https://graph.microsoft.com/Chat.Read';

/// A [GraphAuth] whose browser round is a script: each entry is either the
/// authorization code that round returns, or the exception it throws.
class ScriptedAuth extends GraphAuth {
  final List<Object> script;

  /// The `scope` parameter of every round, in order.
  final List<String> roundScopes = [];

  ScriptedAuth(
    this.script, {
    super.httpClient,
    super.store,
    super.scopeOverride,
    super.extendedScopeOverride,
  });

  @override
  Future<String> authorizeRound({
    required String scopeParam,
    required String challenge,
    required String state,
  }) async {
    roundScopes.add(scopeParam);
    final step = script.removeAt(0);
    if (step is Exception) throw step;
    return step as String;
  }
}

void main() {
  late InMemoryTokenStore store;

  setUp(() {
    store = InMemoryTokenStore();
    store.values['refresh_token'] = 'rt-initial';
  });

  http.Response ok(String body) =>
      http.Response(body, 200, headers: {'content-type': 'application/json'});

  /// Answers the token POST and the `/me` GET, and records the scope every
  /// token request asked for.
  MockClient tokenAndMe(List<String?> tokenScopes, {String grant = coreGrant}) {
    return MockClient((request) async {
      if (request.url.path.endsWith('/oauth2/v2.0/token')) {
        tokenScopes.add(request.bodyFields['scope']);
        return ok(jsonEncode({
          'access_token': 'at-1',
          'refresh_token': 'rt-1',
          'expires_in': 3600,
          'scope': grant,
          'token_type': 'Bearer',
        }));
      }
      return ok(jsonEncode({'displayName': 'Ada Lovelace'}));
    });
  }

  group('the required / extended split', () {
    test('the core grant alone is not a re-consent', () async {
      // What a tenant that refused Mail.Send leaves behind. The session is
      // perfectly usable; treating it as re-consent would loop the user
      // through a sign-in nobody can complete.
      store.values['granted_scopes'] = coreGrant;
      final auth = GraphAuth(store: store);

      expect(await auth.needsReconsent, isFalse);
      expect(await auth.hasScope('mail.send'), isFalse);
      expect(await auth.hasScope('chat.read'), isFalse);
      expect(await auth.hasScope('mail.read'), isTrue);
    });

    test('the full grant enables everything', () async {
      store.values['granted_scopes'] = fullGrant;
      final auth = GraphAuth(store: store);

      expect(await auth.needsReconsent, isFalse);
      expect(await auth.hasScope('mail.send'), isTrue);
      expect(await auth.hasScope('mail.readwrite'), isTrue);
      expect(await auth.hasScope('chat.read'), isTrue);
    });

    test('a missing CORE scope still demands re-consent', () async {
      store.values['granted_scopes'] =
          'https://graph.microsoft.com/User.Read';
      final auth = GraphAuth(store: store);

      expect(await auth.needsReconsent, isTrue);
    });

    test('hasScope is false when nothing is stored', () async {
      final auth = GraphAuth(store: InMemoryTokenStore());

      expect(await auth.hasScope('mail.send'), isFalse);
      expect(await auth.hasScope('mail.read'), isFalse);
    });

    test('the requested list is core then extended', () {
      expect(GraphAuth.scopes, [
        ...GraphAuth.coreScopes,
        ...GraphAuth.extendedScopes,
      ]);
    });

    test('admin-gated scopes are wanted but never requested', () {
      // Chat.Read needs admin consent at this tenant, and one admin-gated
      // scope in the authorize bundle walls off the whole request behind an
      // "Approval required" page — including the mail scopes the user could
      // have granted alone. It must sit out of the request until approved.
      expect(GraphAuth.pendingAdminScopes, contains('Chat.Read'));
      expect(GraphAuth.scopes, isNot(contains('Chat.Read')));
      expect(GraphAuth.extendedScopes, isNot(contains('Chat.Read')));
    });
  });

  group('subsumption', () {
    test('Mail.ReadWrite satisfies Mail.Read', () async {
      // Entra's own consent hierarchy: a grant of the write scope includes the
      // read one, and it does not list both.
      store.values['granted_scopes'] =
          'https://graph.microsoft.com/Mail.ReadWrite '
          'https://graph.microsoft.com/User.Read';
      final auth = GraphAuth(store: store);

      expect(await auth.hasScope('mail.read'), isTrue);
      expect(await auth.needsReconsent, isFalse,
          reason: 'the core set wants Mail.Read, and this grant covers it');
    });

    test('and nothing else subsumes anything', () async {
      store.values['granted_scopes'] = fullGrant;
      final auth = GraphAuth(store: store);

      // Mail.Read does NOT stand in for Mail.ReadWrite, in either direction
      // beyond the one pair above.
      store.values['granted_scopes'] = coreGrant;
      expect(await auth.hasScope('mail.readwrite'), isFalse);
    });
  });

  group('scopeOverride keeps its old meaning', () {
    test('a newly added scope demands re-consent without any token POST',
        () async {
      // Copied from auth_refresh_test: the override is BOTH the required and
      // the requested set, and it turns the extended set off.
      store.values['granted_scopes'] = coreGrant;
      var posts = 0;
      final auth = GraphAuth(
        httpClient: MockClient((_) async {
          posts++;
          return ok('{}');
        }),
        store: store,
        scopeOverride: const [
          'Mail.Read',
          'User.Read',
          'Chat.Read',
          'offline_access',
        ],
      );

      expect(await auth.needsReconsent, isTrue);
      await expectLater(
        auth.getValidAccessToken(),
        throwsA(isA<ReconsentRequired>()),
      );
      expect(posts, 0);
    });

    test('and asks for exactly what it names, extended set empty', () async {
      store.values['granted_scopes'] = coreGrant;
      final scopes = <String?>[];
      final auth = ScriptedAuth(
        ['code-1'],
        httpClient: tokenAndMe(scopes),
        store: store,
        scopeOverride: const ['Mail.Read', 'offline_access'],
      );

      await auth.signIn();

      expect(auth.roundScopes, ['Mail.Read offline_access']);
      expect(scopes.single, 'Mail.Read offline_access');
    });
  });

  group('consent degrade', () {
    /// A tenant that will not grant the extended scopes. AADSTS90094 arrives
    /// as `access_denied`, which is the same code a Cancel click produces —
    /// the description is the only thing that separates them.
    AuthorizeDenied adminConsentRequired() => const AuthorizeDenied(
          'access_denied',
          'AADSTS90094: The grant requires admin permission.',
          'Microsoft did not complete sign-in',
        );

    ScriptedAuth degradable(
      List<Object> script,
      MockClient client,
    ) =>
        ScriptedAuth(
          script,
          httpClient: client,
          store: store,
          scopeOverride: const ['Mail.Read', 'User.Read', 'offline_access'],
          extendedScopeOverride: const ['Mail.Send'],
        );

    test('AADSTS90094 retries ONCE with the core scopes only', () async {
      final scopes = <String?>[];
      final auth = degradable(
        [adminConsentRequired(), 'code-2'],
        tokenAndMe(scopes),
      );

      final account = await auth.signIn();

      expect(account.displayName, 'Ada Lovelace');
      expect(auth.roundScopes, [
        'Mail.Read User.Read offline_access Mail.Send',
        'Mail.Read User.Read offline_access',
      ]);
      // The token exchange happened only for the round that succeeded.
      expect(scopes, ['Mail.Read User.Read offline_access']);
      // And the app now honestly reports the feature as unavailable.
      expect(await auth.hasScope('mail.send'), isFalse);
      expect(await auth.needsReconsent, isFalse);
    });

    test('AADSTS65001 degrades too', () async {
      final auth = degradable(
        [
          const AuthorizeDenied(
            'access_denied',
            'AADSTS65001: The user or administrator has not consented.',
            'Microsoft did not complete sign-in',
          ),
          'code-2',
        ],
        tokenAndMe(<String?>[]),
      );

      await auth.signIn();

      expect(auth.roundScopes, hasLength(2));
    });

    test('so does an explicit consent_required', () async {
      final auth = degradable(
        [
          const AuthorizeDenied('consent_required', '', 'no consent'),
          'code-2',
        ],
        tokenAndMe(<String?>[]),
      );

      await auth.signIn();

      expect(auth.roundScopes, hasLength(2));
    });

    test('a plain access_denied is a Cancel click and is NOT retried',
        () async {
      // The user backed out. Reopening the browser at them would be the app
      // arguing with a decision they just made.
      final auth = degradable(
        [
          const AuthorizeDenied(
            'access_denied',
            'AADSTS50126: the user cancelled.',
            'Microsoft did not complete sign-in',
          ),
        ],
        tokenAndMe(<String?>[]),
      );

      await expectLater(auth.signIn(), throwsA(isA<AuthorizeDenied>()));
      expect(auth.roundScopes, hasLength(1));
    });

    test('a refused SECOND round throws rather than trying a third', () async {
      final auth = degradable(
        [adminConsentRequired(), adminConsentRequired()],
        tokenAndMe(<String?>[]),
      );

      await expectLater(auth.signIn(), throwsA(isA<AuthorizeDenied>()));
      expect(auth.roundScopes, hasLength(2));
    });

    test('with no extended scopes there is nothing to degrade to', () async {
      final auth = ScriptedAuth(
        [adminConsentRequired()],
        httpClient: tokenAndMe(<String?>[]),
        store: store,
        scopeOverride: const ['Mail.Read', 'offline_access'],
      );

      await expectLater(auth.signIn(), throwsA(isA<AuthorizeDenied>()));
      expect(auth.roundScopes, hasLength(1));
    });
  });

  group('the refresh asks only for what was granted', () {
    test('a degraded session is not signed out on its first refresh', () async {
      // The bug this exists to stop: refreshing with Mail.Send in the scope
      // list, against a grant that never included it, comes back invalid_grant
      // — which reads as "signed out" and clears the keychain.
      store.values['granted_scopes'] = coreGrant;
      final scopes = <String?>[];
      final auth = GraphAuth(httpClient: tokenAndMe(scopes), store: store);

      await auth.getValidAccessToken();

      expect(scopes.single, 'Mail.Read User.Read offline_access');
      expect(store.values['refresh_token'], 'rt-1');
    });

    test('a full grant refreshes with everything', () async {
      store.values['granted_scopes'] = fullGrant;
      final scopes = <String?>[];
      final auth = GraphAuth(
        httpClient: tokenAndMe(scopes, grant: fullGrant),
        store: store,
      );

      await auth.getValidAccessToken();

      expect(scopes.single, GraphAuth.scopes.join(' '));
    });

    test('with nothing stored it asks for the whole list', () async {
      final scopes = <String?>[];
      final auth = GraphAuth(httpClient: tokenAndMe(scopes), store: store);

      await auth.getValidAccessToken();

      expect(scopes.single, GraphAuth.scopes.join(' '));
    });
  });
}
