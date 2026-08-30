import 'dart:convert';

import 'package:bond_inbox/services/graph_auth.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A [TokenStore] backed by a map — the plugin-free stand-in for the keychain.
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

/// The scope string Entra actually returns for this registration:
/// resource-qualified, case-folded, and without `offline_access`.
const String grantedScopesFromEntra =
    'https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read';

String tokenJson({
  required String accessToken,
  required String refreshToken,
  int expiresIn = 3600,
  String scope = grantedScopesFromEntra,
}) =>
    jsonEncode({
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': expiresIn,
      'scope': scope,
      'token_type': 'Bearer',
    });

void main() {
  late InMemoryTokenStore store;
  late int tokenPosts;

  setUp(() {
    store = InMemoryTokenStore();
    store.values['refresh_token'] = 'rt-initial';
    store.values['granted_scopes'] = grantedScopesFromEntra;
    tokenPosts = 0;
  });

  /// Counts token POSTs and answers each with [respond].
  MockClient countingClient(http.Response Function(int call) respond) {
    return MockClient((request) async {
      expect(request.url.path, endsWith('/oauth2/v2.0/token'));
      // Public client: a secret here would make Entra reject the exchange.
      expect(request.bodyFields, isNot(contains('client_secret')));
      tokenPosts++;
      return respond(tokenPosts);
    });
  }

  http.Response ok(String body) =>
      http.Response(body, 200, headers: {'content-type': 'application/json'});

  test('concurrent callers share one refresh and store the rotated token',
      () async {
    final auth = GraphAuth(
      httpClient: countingClient(
        (call) => ok(tokenJson(
          accessToken: 'at-$call',
          refreshToken: 'rt-$call',
          // Inside the 5-minute margin, so the cached token is already
          // considered expired on the next call.
          expiresIn: call == 1 ? 60 : 3600,
        )),
      ),
      store: store,
    );

    // Prime the in-memory token with one that expires inside the margin.
    expect(await auth.getValidAccessToken(), 'at-1');
    expect(tokenPosts, 1);
    tokenPosts = 0;

    final results = await Future.wait([
      for (var i = 0; i < 10; i++) auth.getValidAccessToken(),
    ]);

    expect(tokenPosts, 1, reason: 'ten callers must share one refresh');
    expect(results, everyElement('at-1'));
    expect(store.values['refresh_token'], 'rt-1',
        reason: 'Microsoft rotates refresh tokens; the new one must be stored');
  });

  test('a failed refresh clears the single-flight slot and keeps storage',
      () async {
    final auth = GraphAuth(
      httpClient: countingClient((_) => http.Response('gateway down', 500)),
      store: store,
    );

    await expectLater(auth.getValidAccessToken(), throwsA(isA<AuthException>()));
    await expectLater(auth.getValidAccessToken(), throwsA(isA<AuthException>()));

    expect(tokenPosts, 2, reason: 'the second call must retry, not reawait');
    expect(store.values['refresh_token'], 'rt-initial',
        reason: 'a transient failure must not sign the user out');
  });

  test('invalid_grant signs the user out and clears storage', () async {
    final auth = GraphAuth(
      httpClient: countingClient(
        (_) => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description': 'AADSTS700082: The refresh token has expired.',
          }),
          400,
          headers: {'content-type': 'application/json'},
        ),
      ),
      store: store,
    );

    await expectLater(auth.getValidAccessToken(), throwsA(isA<NotSignedIn>()));
    expect(store.values, isEmpty);
    expect(await auth.isSignedIn, isFalse);
  });

  test('resource-qualified grants satisfy the configured scopes', () async {
    final auth = GraphAuth(
      httpClient: countingClient((_) => ok(tokenJson(
            accessToken: 'at-1',
            refreshToken: 'rt-1',
          ))),
      store: store,
      scopeOverride: const ['Mail.Read', 'User.Read', 'offline_access'],
    );

    expect(await auth.needsReconsent, isFalse);
    expect(await auth.getValidAccessToken(), 'at-1');
    expect(tokenPosts, 1);
  });

  test('a newly added scope demands re-consent without any token POST',
      () async {
    final auth = GraphAuth(
      httpClient: countingClient((_) => ok(tokenJson(
            accessToken: 'at-1',
            refreshToken: 'rt-1',
          ))),
      store: store,
      // What adding Teams support looks like against an older grant.
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
    expect(tokenPosts, 0,
        reason: 'refreshing an unconsented scope returns AADSTS65001, which '
            'masquerades as a signed-out session');
  });

  test('signOut clears storage', () async {
    final auth = GraphAuth(
      httpClient: countingClient((_) => ok('{}')),
      store: store,
    );
    store.values['account_json'] = jsonEncode({'displayName': 'Ada Lovelace'});

    expect(await auth.isSignedIn, isTrue);
    await auth.signOut();

    expect(store.values, isEmpty);
    expect(await auth.isSignedIn, isFalse);
    expect(await auth.storedAccount, isNull);
    expect(tokenPosts, 0);
  });

  test('needsReconsent is false when nothing is stored', () async {
    final auth = GraphAuth(
      httpClient: countingClient((_) => ok('{}')),
      store: InMemoryTokenStore(),
    );

    expect(await auth.needsReconsent, isFalse);
    await expectLater(auth.getValidAccessToken(), throwsA(isA<NotSignedIn>()));
  });

  test('a supplied dev-stage client secret rides on the refresh POST',
      () async {
    // The counterpart of countingClient's no-secret assertion above: this
    // registration is confidential in dev, and BOTH grant types fail with
    // AADSTS7000218 unless the secret is present when one was supplied.
    String? seenSecret;
    final client = MockClient((request) async {
      seenSecret = request.bodyFields['client_secret'];
      return ok(tokenJson(accessToken: 'at', refreshToken: 'rt-2'));
    });
    final auth = GraphAuth(
      httpClient: client,
      store: store,
      clientSecret: 'shhh',
    );

    await auth.getValidAccessToken();
    expect(seenSecret, 'shhh');
  });
}
