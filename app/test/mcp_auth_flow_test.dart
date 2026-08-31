import 'dart:convert';

import 'package:bond_inbox/services/backend/backend_types.dart';
import 'package:bond_inbox/services/mcp/bond_mcp_client.dart';
import 'package:bond_inbox/services/mcp/mcp_auth.dart';
import 'package:bond_inbox/services/pkce.dart';
import 'package:bond_inbox/services/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The sign-in and token-refresh rounds of [McpAuthSession], end to end
/// against a scripted authorization server and a REAL loopback listener — the
/// browser is the only thing replaced, because the request matching on that
/// socket is the part worth pinning.
///
/// The stubs here are deliberately duplicated from the other MCP tests rather
/// than shared, so no file can break another by editing it.
class _Tokens implements TokenStore {
  final Map<String, String> values = {};
  bool deleteAllCalled = false;

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
  Future<void> deleteAll() async {
    deleteAllCalled = true;
    values.clear();
  }
}

class _FakeBondMcpClient implements BondMcpClient {
  final Map<String, Object> scripted;

  _FakeBondMcpClient(this.scripted);

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    final reply = scripted[name];
    if (reply is Map<String, dynamic>) return reply;
    if (reply == null) throw McpTransportException('no script for "$name"');
    throw reply;
  }

  @override
  Future<void> close() async {}
}

const String _mcp = 'https://mcp.example.test/mcp';
const String _prm =
    'https://mcp.example.test/.well-known/oauth-protected-resource/mcp';
const String _issuer = 'https://auth.example.test';
const String _asMetadata =
    '$_issuer/.well-known/oauth-authorization-server';
const String _authorizeEndpoint = '$_issuer/oauth/authorize';
const String _tokenEndpoint = '$_issuer/oauth/token';

/// The local `make dev` server, the second endpoint this file signs in to.
/// Its session lives in its own keychain slot, which is the entire point of
/// naming it separately from [_mcp].
const String _localMcp = 'http://localhost:18001/mcp';

/// The key names one server's session reads and writes, read off a session
/// rather than spelled out: a slot is a digest of the URL, and a test that
/// hardcoded that digest would pin the derivation instead of the behaviour.
McpAuthSession _keysFor(String url) => McpAuthSession(
      mcpUrl: Uri.parse(url),
      mcpClient: _FakeBondMcpClient(const {}),
      store: _Tokens(),
    );

final McpAuthSession _keys = _keysFor(_mcp);
final McpAuthSession _localKeys = _keysFor(_localMcp);

/// A JWT whose payload really decodes — only `exp` and the identity claims are
/// ever read, and never to decide validity.
String _jwt(Map<String, dynamic> claims) {
  final payload =
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return 'aGVhZGVy.$payload.c2ln';
}

String _liveJwt({String? email}) => _jwt({
      'sub': 'user-1',
      'email': ?email,
      'exp': DateTime.now()
              .add(const Duration(hours: 24))
              .millisecondsSinceEpoch ~/
          1000,
    });

/// Records what the scripted authorization server was asked.
class _Server {
  final List<Map<String, String>> tokenPosts = [];
  final List<Uri> gets = [];

  /// Replies for the token endpoint, one per POST; the last one repeats.
  List<http.Response> tokenReplies = [];

  MockClient get client => MockClient((request) async {
        final url = request.url.toString();
        if (request.method == 'POST' && url == _tokenEndpoint) {
          tokenPosts.add(request.bodyFields);
          return tokenReplies.length == 1
              ? tokenReplies.first
              : tokenReplies.removeAt(0);
        }
        gets.add(request.url);
        switch (url) {
          case _mcp:
            return http.Response(
              'unauthorized',
              401,
              headers: {
                'www-authenticate': 'Bearer error="invalid_token", '
                    'resource_metadata="$_prm"',
              },
            );
          case _prm:
            return http.Response(
              jsonEncode({
                'resource': _mcp,
                'authorization_servers': [_issuer],
              }),
              200,
            );
          case _asMetadata:
            return http.Response(
              jsonEncode({
                'issuer': _issuer,
                'authorization_endpoint': _authorizeEndpoint,
                'token_endpoint': _tokenEndpoint,
                'code_challenge_methods_supported': ['S256'],
                'token_endpoint_auth_methods_supported': ['none'],
              }),
              200,
            );
        }
        return http.Response('unexpected ${request.method} $url', 404);
      });
}

http.Response _tokenOk({
  required String accessToken,
  String? refreshToken,
}) =>
    http.Response(
      jsonEncode({
        'access_token': accessToken,
        'token_type': 'Bearer',
        'expires_in': 86400,
        'refresh_token': ?refreshToken,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('signIn against an authorization server', () {
    late _Server server;
    late _Tokens store;
    late List<Uri> opened;
    late List<Future<void>> callbacks;

    /// The browser stand-in: records the authorize URL and drives the loopback
    /// listener the way a real redirect would. Extra requests named in
    /// [strays] are sent FIRST, so the genuine callback has to win past them.
    Future<bool> Function(Uri) browser({
      List<Map<String, String>> strays = const [],
    }) =>
        (Uri authorizeUrl) async {
          opened.add(authorizeUrl);
          final callbackBase = Uri.parse(McpAuthSession.redirectUri);
          for (final params in strays) {
            callbacks.add(_fire(callbackBase.replace(queryParameters: params)));
          }
          callbacks.add(_fire(callbackBase.replace(queryParameters: {
            'state': authorizeUrl.queryParameters['state']!,
            'code': 'the-auth-code',
          })));
          return true;
        };

    setUp(() {
      server = _Server();
      store = _Tokens();
      opened = [];
      callbacks = [];
    });

    tearDown(() => Future.wait(callbacks));

    McpAuthSession sessionWith(
      Future<bool> Function(Uri) openBrowser, {
      Map<String, Object> tools = const {},
    }) =>
        McpAuthSession(
          mcpUrl: Uri.parse(_mcp),
          mcpClient: _FakeBondMcpClient(tools),
          httpClient: server.client,
          store: store,
          openBrowser: openBrowser,
        );

    test('walks discovery, authorizes, and exchanges the code', () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(browser(), tools: {
        'get_profile_json': {
          'id': 'u1',
          'display_name': 'Ada Lovelace',
          'mail': 'ada@example.test',
          'user_principal_name': 'ada@example.test',
        },
      });

      final account = await auth.signIn();

      // Discovery followed the challenge rather than guessing the path.
      expect(server.gets.map((u) => u.toString()),
          containsAllInOrder([_mcp, _prm, _asMetadata]));

      final authorize = opened.single;
      expect(authorize.origin + authorize.path, _authorizeEndpoint);
      final q = authorize.queryParameters;
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'bond-desktop');
      expect(q['redirect_uri'], 'http://127.0.0.1:8766/callback');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      // RFC 8707 on the authorize request: the audience is bound at this step.
      expect(q['resource'], _mcp);
      // This authorization server issues what the client is registered for.
      expect(q.containsKey('scope'), isFalse);

      final post = server.tokenPosts.single;
      expect(post['grant_type'], 'authorization_code');
      expect(post['code'], 'the-auth-code');
      expect(post['client_id'], 'bond-desktop');
      expect(post['redirect_uri'], 'http://127.0.0.1:8766/callback');
      // ...and on the token request, or the JWT comes back with an `aud` the
      // MCP server will not accept.
      expect(post['resource'], _mcp);
      // The verifier really is the one the challenge was built from.
      expect(pkceChallengeFor(post['code_verifier']!), q['code_challenge']);

      expect(account.displayName, 'Ada Lovelace');
      expect(account.mail, 'ada@example.test');
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
      expect(store.values[_keys.accountJsonKey], isNotNull);
      expect(await auth.isSignedIn, isTrue);
    });

    test('the Graph session\'s keys are untouched by an MCP sign-in', () async {
      store.values['refresh_token'] = 'graph-rt';
      store.values['granted_scopes'] = 'Mail.Read User.Read';
      store.values['account_json'] = '{"displayName":"Graph User"}';
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];

      await sessionWith(browser(), tools: {
        'get_profile_json': {'display_name': 'Ada', 'mail': 'ada@example.test'},
      }).signIn();

      expect(store.values['refresh_token'], 'graph-rt');
      expect(store.values['granted_scopes'], 'Mail.Read User.Read');
      expect(store.values['account_json'], '{"displayName":"Graph User"}');
    });

    test('stray requests on the port do not consume the sign-in', () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(
        browser(strays: [
          // A poll with no sign-in parameters at all.
          const {'ping': '1'},
          // A forged callback carrying a code but the wrong state.
          const {'state': 'wrong', 'code': 'attacker'},
        ]),
        tools: {
          'get_profile_json': {'display_name': 'Ada', 'mail': 'ada@example.test'},
        },
      );

      await auth.signIn();
      expect(server.tokenPosts.single['code'], 'the-auth-code');
    });

    test('an authorization-server sign-in clears a stale local-mode flag',
        () async {
      // The mirror of the local path forgetting the refresh token: after a
      // Local → Deployed switch, a stale flag would let validJwt answer "no
      // bearer needed" the day the refresh token is gone, instead of the
      // honest NotSignedIn.
      store.values[_keys.localModeKey] = '1';
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];

      await sessionWith(browser(), tools: {
        'get_profile_json': {'display_name': 'Ada', 'mail': 'ada@example.test'},
      }).signIn();

      expect(store.values.containsKey(_keys.localModeKey), isFalse);
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('a refusal on the callback is AuthorizeDenied, not a hang', () async {
      final auth = sessionWith((Uri authorizeUrl) async {
        opened.add(authorizeUrl);
        callbacks.add(_fire(
          Uri.parse(McpAuthSession.redirectUri).replace(queryParameters: {
            'state': authorizeUrl.queryParameters['state']!,
            'error': 'access_denied',
            'error_description': 'the user said no',
          }),
        ));
        return true;
      });

      await expectLater(auth.signIn(), throwsA(isA<AuthorizeDenied>()));
      expect(server.tokenPosts, isEmpty);
    });

    test('a rejected token exchange is an AuthException', () async {
      server.tokenReplies = [
        http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description': 'the code has already been used',
          }),
          400,
        ),
      ];
      final auth = sessionWith(browser());

      await expectLater(
        auth.signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            'the code has already been used')),
      );
      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
    });

    test('signing in without a connected account still signs in', () async {
      // A legitimate state: the platform token is good, but no Microsoft
      // account is attached yet. The user is named from the JWT and the UI
      // gets to offer the connect step.
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(browser(), tools: {
        'get_profile_json': {'error': 'not_connected', 'connect_url': null},
      });

      final account = await auth.signIn();
      expect(account.displayName, 'ada@example.test');
      expect(account.mail, 'ada@example.test');
      // Nothing to persist — there is no profile behind it yet.
      expect(store.values.containsKey(_keys.accountJsonKey), isFalse);
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('an unreachable profile tool does not fail the sign-in', () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(browser(), tools: {
        'get_profile_json': const McpTransportException('connection reset'),
      });

      // No `email` claim, so the subject is the only name available.
      expect((await auth.signIn()).displayName, 'user-1');
    });
  });

  group('signIn against a server that wants no token', () {
    /// The local `make dev` server: a bare GET is answered, not challenged.
    MockClient localServer() => MockClient((request) async =>
        http.Response('Method Not Allowed', 405));

    test('records local mode and needs no browser', () async {
      final store = _Tokens();
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient({
          'get_profile_json': {'error': 'not_connected', 'connect_url': null},
        }),
        httpClient: localServer(),
        store: store,
        openBrowser: (_) async => fail('a local server must not open a browser'),
      );

      final account = await auth.signIn();
      expect(account.displayName, 'Local session');
      expect(store.values[_localKeys.localModeKey], '1');
      expect(store.values.containsKey(_localKeys.accountJsonKey), isFalse);
      expect(await auth.isSignedIn, isTrue);
    });

    test('a profile the local server can answer is used and stored', () async {
      final store = _Tokens();
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient({
          'get_profile_json': {
            'display_name': 'Ada Lovelace',
            'mail': 'ada@example.test',
            'user_principal_name': 'ada@corp.example.test',
          },
        }),
        httpClient: localServer(),
        store: store,
        openBrowser: (_) async => fail('a local server must not open a browser'),
      );

      final account = await auth.signIn();
      expect(account.displayName, 'Ada Lovelace');
      expect(account.userPrincipalName, 'ada@corp.example.test');
      expect(store.values[_localKeys.accountJsonKey], isNotNull);
    });

    test('a local sign-in forgets a refresh token in the same slot', () async {
      // Within ONE server's slot the two markers stay mutually exclusive: the
      // same URL can be challenged today and open tomorrow (a local server
      // rebooted with auth off is the everyday case). A refresh token left in
      // this slot would win over the local-mode flag in validJwt and send a
      // refresh at a server with no token endpoint to discover — breaking
      // every call until a sign-out.
      final store = _Tokens()..values[_localKeys.refreshTokenKey] = 'stale-deployed-rt';
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient({
          'get_profile_json': {'error': 'not_connected', 'connect_url': null},
        }),
        httpClient: localServer(),
        store: store,
        openBrowser: (_) async => fail('a local server must not open a browser'),
      );

      await auth.signIn();
      expect(store.values.containsKey(_localKeys.refreshTokenKey), isFalse);
      expect(store.values[_localKeys.localModeKey], '1');
      expect(await auth.validJwt(), isNull);
    });

    test('validJwt sends no bearer in local mode', () async {
      final store = _Tokens()..values[_localKeys.localModeKey] = '1';
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient(const {}),
        httpClient: localServer(),
        store: store,
      );
      expect(await auth.validJwt(), isNull);
    });
  });

  group('validJwt', () {
    late _Server server;
    late _Tokens store;

    McpAuthSession session() => McpAuthSession(
          mcpUrl: Uri.parse(_mcp),
          mcpClient: _FakeBondMcpClient(const {}),
          httpClient: server.client,
          store: store,
        );

    setUp(() {
      server = _Server();
      store = _Tokens()..values[_keys.refreshTokenKey] = 'rt-1';
    });

    test('refreshes after a relaunch by re-walking discovery', () async {
      server.tokenReplies = [_tokenOk(accessToken: _liveJwt())];
      final auth = session();

      expect(await auth.validJwt(), isNotNull);
      expect(server.gets.map((u) => u.toString()),
          containsAllInOrder([_mcp, _prm, _asMetadata]));
      expect(server.tokenPosts.single['grant_type'], 'refresh_token');
      expect(server.tokenPosts.single['refresh_token'], 'rt-1');
      expect(server.tokenPosts.single['client_id'], 'bond-desktop');
      expect(server.tokenPosts.single['resource'], _mcp);
    });

    test('a fresh token is reused without another exchange', () async {
      server.tokenReplies = [_tokenOk(accessToken: _liveJwt())];
      final auth = session();

      final first = await auth.validJwt();
      expect(await auth.validJwt(), first);
      expect(server.tokenPosts, hasLength(1));
    });

    test('concurrent callers share ONE refresh', () async {
      // Refresh tokens rotate here: a second exchange would race on an
      // already-consumed one.
      server.tokenReplies = [_tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-2')];
      final auth = session();

      final results = await Future.wait([auth.validJwt(), auth.validJwt()]);
      expect(results.first, results.last);
      expect(server.tokenPosts, hasLength(1));
    });

    test('a rotated refresh token replaces the stored one', () async {
      server.tokenReplies = [_tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-2')];
      await session().validJwt();
      expect(store.values[_keys.refreshTokenKey], 'rt-2');
    });

    test('invalid_grant ends the session, and only this one', () async {
      store.values['refresh_token'] = 'graph-rt';
      store.values['granted_scopes'] = 'Mail.Read User.Read';
      store.values['account_json'] = '{"displayName":"Graph User"}';
      store.values[_keys.accountJsonKey] = '{"displayName":"Ada"}';
      store.values[_keys.localModeKey] = '1';
      server.tokenReplies = [
        http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
      ];

      await expectLater(session().validJwt(), throwsA(isA<NotSignedIn>()));

      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
      expect(store.values.containsKey(_keys.accountJsonKey), isFalse);
      expect(store.values.containsKey(_keys.localModeKey), isFalse);
      expect(store.values['refresh_token'], 'graph-rt');
      expect(store.values['granted_scopes'], 'Mail.Read User.Read');
      expect(store.values['account_json'], '{"displayName":"Graph User"}');
      expect(store.deleteAllCalled, isFalse);
    });

    test('a server error is transient: the refresh token survives', () async {
      server.tokenReplies = [http.Response('upstream exploded', 500)];

      await expectLater(session().validJwt(), throwsA(isA<AuthException>()));
      // Clearing here would turn a dropped network into a forced sign-out.
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('a failed refresh does not poison the next attempt', () async {
      server.tokenReplies = [
        http.Response('upstream exploded', 500),
        _tokenOk(accessToken: _liveJwt()),
      ];
      final auth = session();

      await expectLater(auth.validJwt(), throwsA(isA<AuthException>()));
      expect(await auth.validJwt(), isNotNull);
      expect(server.tokenPosts, hasLength(2));
    });

    test('no stored token and no local mode is NotSignedIn', () async {
      store.values.remove(_keys.refreshTokenKey);
      await expectLater(session().validJwt(), throwsA(isA<NotSignedIn>()));
      expect(server.tokenPosts, isEmpty);
    });

    test('the expiry comes from the JWT\'s own exp claim', () async {
      // `expires_in` is measured against a clock we did not read when the
      // server did; `exp` is what the server will actually enforce. A token
      // already past it must not be handed out however long `expires_in` says.
      final expired = _jwt({
        'sub': 'user-1',
        'exp':
            DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                1000,
      });
      server.tokenReplies = [
        _tokenOk(accessToken: expired),
        _tokenOk(accessToken: _liveJwt()),
      ];
      final auth = session();

      await auth.validJwt();
      await auth.validJwt();
      expect(server.tokenPosts, hasLength(2));
    });
  });
}

/// Drives the loopback listener the way a browser redirect would. Failures are
/// swallowed: the server is force-closed the instant sign-in resolves, which
/// can cut the socket before the reply is fully read.
Future<void> _fire(Uri url) =>
    http.get(url).then((_) {}, onError: (Object _) {});
