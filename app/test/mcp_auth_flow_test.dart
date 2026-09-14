import 'dart:async';
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
const String _registerEndpoint = '$_issuer/oauth/register';

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
      refreshRetryDelay: Duration.zero,
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

  /// Every non-token URL asked for, in order. The sign-in probe is among them
  /// and is a POST — the endpoint is what these assertions are about, not the
  /// verb.
  final List<Uri> gets = [];

  /// The sign-in probes, whole: the request that pins the probe's shape reads
  /// its method and body back out of here.
  final List<http.Request> probes = [];

  /// Replies for the token endpoint, one per POST; the last one repeats.
  ///
  /// An [http.Response] is answered with. An [Exception] is THROWN out of the
  /// client instead, which is how a request that never reached a server — a
  /// reset connection — is scripted.
  List<Object> tokenReplies = [];

  /// When set, the token endpoint waits on this before answering, which is how
  /// a refresh is held in flight while the test does something else to the
  /// same slot.
  ///
  /// Stays armed once set: a completed hold no longer blocks anything, so
  /// releasing it lets every later token POST through, while a hold that is
  /// never completed freezes ALL of them — which is what a request that hangs
  /// until the timeout fires looks like, retry included.
  Completer<void>? holdToken;

  /// When set, the authorization-server metadata GET waits on this before
  /// answering: the way to freeze a refresh in DISCOVERY, which runs outside
  /// the slot lock, rather than at the token POST, which runs inside it.
  Completer<void>? holdMetadata;

  /// When true the MCP endpoint answers the initialize POST instead of
  /// challenging it: the same URL turning into an open dev server, which is
  /// what a local box rebooted with auth off looks like.
  bool openServer = false;

  /// The `registration_endpoint` the RFC 8414 metadata carries, verbatim.
  /// Every bond-mcps server publishes a real URL; null is the foreign server
  /// the static client exists for, and a malformed value is a document the
  /// app must read as "no registration" rather than post to.
  String? registrationEndpoint = _registerEndpoint;

  /// Every registration body this server was sent, decoded, in order.
  final List<Map<String, dynamic>> registrations = [];

  /// What the registration endpoint answers, as a function of the body it was
  /// sent so the default can echo the redirect URIs back.
  http.Response Function(Map<String, dynamic> body) registerReply =
      _registerOk('bm-test-1');

  MockClient get client => MockClient((request) async {
        final url = request.url.toString();
        if (request.method == 'POST' && url == _tokenEndpoint) {
          // Recorded BEFORE the hold, so a test can spin until the exchange it
          // is about to freeze has actually been sent.
          tokenPosts.add(request.bodyFields);
          await holdToken?.future;
          final reply = tokenReplies.length == 1
              ? tokenReplies.first
              : tokenReplies.removeAt(0);
          if (reply is Exception) throw reply;
          return reply as http.Response;
        }
        // Before the fall-through below, which would file a registration under
        // `gets` and answer it 404.
        if (request.method == 'POST' && url == _registerEndpoint) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          registrations.add(body);
          return registerReply(body);
        }
        gets.add(request.url);
        if (request.method == 'POST' && url == _mcp) probes.add(request);
        switch (url) {
          // The deployed shape: the initialize POST is challenged, and the
          // challenge is where the discovery chain starts.
          case _mcp:
            if (openServer) {
              return http.Response(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': 0,
                  'result': {'protocolVersion': '2025-03-26'},
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
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
            await holdMetadata?.future;
            return http.Response(
              jsonEncode({
                'issuer': _issuer,
                'authorization_endpoint': _authorizeEndpoint,
                'token_endpoint': _tokenEndpoint,
                if (registrationEndpoint != null)
                  'registration_endpoint': registrationEndpoint,
                'code_challenge_methods_supported': ['S256'],
                'token_endpoint_auth_methods_supported': ['none'],
              }),
              200,
            );
        }
        return http.Response('unexpected ${request.method} $url', 404);
      });
}

/// The 201 a registration really gets back, echoing the redirect URIs it was
/// handed. Only `client_id` is read by the app; the rest is here so the reply
/// has the shape the real server answers with.
http.Response Function(Map<String, dynamic>) _registerOk(String clientId) =>
    (body) => http.Response(
          jsonEncode({
            'client_id': clientId,
            'client_id_issued_at': 1,
            'client_secret_expires_at': 0,
            'redirect_uris': body['redirect_uris'],
            'grant_types': ['authorization_code', 'refresh_token'],
            'response_types': ['code'],
            'token_endpoint_auth_method': 'none',
            'client_name': 'Bond Desktop',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );

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
          // Wherever the authorize request said to come back to — which with a
          // registered client is a port the OS picked moments ago.
          final callbackBase =
              Uri.parse(authorizeUrl.queryParameters['redirect_uri']!);
          for (final params in strays) {
            callbacks.add(_fire(callbackBase.replace(queryParameters: params)));
          }
          callbacks.add(_fire(callbackBase.replace(queryParameters: {
            'state': authorizeUrl.queryParameters['state']!,
            'code': 'the-auth-code',
          })));
          return true;
        };

    /// A token reply that can be frozen mid-flight. Released in tearDown, so a
    /// held request can never outlive the test that froze it.
    late Completer<void> heldToken;

    setUp(() {
      server = _Server();
      store = _Tokens();
      opened = [];
      callbacks = [];
      heldToken = Completer<void>();
    });

    tearDown(() async {
      if (!heldToken.isCompleted) heldToken.complete();
      await Future.wait(callbacks);
    });

    McpAuthSession sessionWith(
      Future<bool> Function(Uri) openBrowser, {
      Map<String, Object> tools = const {},
      Duration? requestTimeout,
    }) =>
        McpAuthSession(
          mcpUrl: Uri.parse(_mcp),
          mcpClient: _FakeBondMcpClient(tools),
          httpClient: server.client,
          store: store,
          openBrowser: openBrowser,
          requestTimeout: requestTimeout,
          // Nothing here waits out the real retry pause.
          refreshRetryDelay: Duration.zero,
        );

    test('reads the profile by its published name', () async {
      // The alias `get_profile_json` has a removal date, and the failure it
      // would leave behind is silent: `_profileAccount` swallows a transport
      // error and answers null, so a sign-in on the dead name still succeeds
      // and just has nobody's name on it. Scripting ONLY the published name
      // and insisting the account arrives is what catches that.
      server.tokenReplies = [
        _tokenOk(
          accessToken: _liveJwt(email: 'ada@example.test'),
          refreshToken: 'rt-1',
        ),
      ];

      final account = await sessionWith(browser(), tools: {
        'get_profile': {'display_name': 'Ada Lovelace', 'mail': 'ada@example.test'},
      }).signIn();

      expect(account.displayName, 'Ada Lovelace');
    });

    test('registers itself, walks discovery, authorizes, and exchanges the code',
        () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(browser(), tools: {
        'get_profile': {
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

      // Nothing was pre-registered: the app registered itself as a public
      // client naming the loopback URI it had already bound.
      final registration = server.registrations.single;
      expect(registration['client_name'], 'Bond Desktop');
      expect(registration['token_endpoint_auth_method'], 'none');
      expect(registration['redirect_uris'], [q['redirect_uri']]);

      final callback = Uri.parse(q['redirect_uri']!);
      expect(callback.scheme, 'http');
      expect(callback.host, '127.0.0.1');
      expect(callback.path, '/callback');
      // The OS picked it (RFC 8252 §7.3), so the static client's fixed port is
      // not what a registered sign-in listens on.
      expect(callback.port, isNot(8766));

      expect(q['response_type'], 'code');
      expect(q['client_id'], 'bm-test-1');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      // RFC 8707 on the authorize request: the audience is bound at this step.
      expect(q['resource'], _mcp);
      // This authorization server issues what the client is registered for.
      expect(q.containsKey('scope'), isFalse);

      final post = server.tokenPosts.single;
      expect(post['grant_type'], 'authorization_code');
      expect(post['code'], 'the-auth-code');
      expect(post['client_id'], 'bm-test-1');
      expect(post['redirect_uri'], q['redirect_uri']);
      // ...and on the token request, or the JWT comes back with an `aud` the
      // MCP server will not accept.
      expect(post['resource'], _mcp);
      // The verifier really is the one the challenge was built from.
      expect(pkceChallengeFor(post['code_verifier']!), q['code_challenge']);

      expect(account.displayName, 'Ada Lovelace');
      expect(account.mail, 'ada@example.test');
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
      // Stored beside the refresh token, because the authorization server
      // binds the two: a refresh has to present this exact client.
      expect(store.values[_keys.clientIdKey], 'bm-test-1');
      expect(store.values[_keys.accountJsonKey], isNotNull);
      expect(await auth.isSignedIn, isTrue);
    });

    test('without a registration endpoint the pre-registered client and its '
        'fixed port are used', () async {
      // A foreign or CDN-stripped authorization server. The static client is
      // the only way in, and its redirect URI names the port it was registered
      // with, so that port has to be the one this listens on.
      server.registrationEndpoint = null;
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];

      await sessionWith(browser(), tools: {
        'get_profile': {'display_name': 'Ada', 'mail': 'ada@example.test'},
      }).signIn();

      expect(server.registrations, isEmpty);
      final q = opened.single.queryParameters;
      expect(q['client_id'], 'bond-desktop');
      expect(q['redirect_uri'], 'http://127.0.0.1:8766/callback');

      final post = server.tokenPosts.single;
      expect(post['client_id'], 'bond-desktop');
      expect(post['redirect_uri'], 'http://127.0.0.1:8766/callback');
      expect(store.values[_keys.clientIdKey], 'bond-desktop');
    });

    for (final malformed in const ['/oauth/register', 'urn:example:register']) {
      test('a registration endpoint that is not an http URL ($malformed) reads '
          'as no registration, not as something to post to', () async {
        // `Uri.tryParse` accepts both of these, and the HTTP client answers a
        // POST to either with an ArgumentError the UI can only render as
        // "Sign-in failed." A malformed document is read the same way as a
        // missing field: the static client, on its fixed port.
        server.registrationEndpoint = malformed;
        server.tokenReplies = [
          _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-1'),
        ];

        await sessionWith(browser()).signIn();

        expect(server.registrations, isEmpty);
        final q = opened.single.queryParameters;
        expect(q['client_id'], 'bond-desktop');
        expect(q['redirect_uri'], 'http://127.0.0.1:8766/callback');
        expect(store.values[_keys.clientIdKey], 'bond-desktop');
      });
    }

    test('a refused registration is an AuthException naming the reason, and '
        'opens no browser', () async {
      // Ambiguity is an error here, never an answer: falling through to a
      // static client the server has probably never heard of would just move
      // the failure into the browser, where this app cannot see it.
      server.registerReply = (_) => http.Response(
            jsonEncode({
              'error': 'invalid_client_metadata',
              'error_description': 'redirect_uris must be a non-empty list.',
            }),
            400,
          );
      final auth = sessionWith(browser());

      await expectLater(
        auth.signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('redirect_uris must be a non-empty list.'))),
      );
      expect(opened, isEmpty);
      expect(server.tokenPosts, isEmpty);
      expect(store.values.containsKey(_keys.clientIdKey), isFalse);
    });

    test('each interactive sign-in registers afresh', () async {
      // A registration is never reused: an id the server has forgotten comes
      // back as a 400 in the BROWSER, which this app never sees, and the URI it
      // was registered with names a port that will not be free next time.
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-1'),
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-2'),
      ];
      final auth = sessionWith(browser());

      await auth.signIn();
      server.registerReply = _registerOk('bm-test-2');
      await auth.signIn();

      expect(server.registrations, hasLength(2));
      expect(opened.last.queryParameters['client_id'], 'bm-test-2');
      expect(store.values[_keys.clientIdKey], 'bm-test-2');
    });

    test('an abandoned sign-in leaves the existing session and its client in '
        'step', () async {
      // The client id is written beside the refresh token, not at
      // registration: a registration that succeeded and a browser round that
      // did not must leave the slot exactly as it was, or the next refresh
      // would present the new client for the old token and be signed out.
      store.values[_keys.refreshTokenKey] = 'rt-old';
      store.values[_keys.clientIdKey] = 'bm-old';
      final auth = sessionWith((Uri authorizeUrl) async {
        opened.add(authorizeUrl);
        callbacks.add(_fire(
          Uri.parse(authorizeUrl.queryParameters['redirect_uri']!)
              .replace(queryParameters: {
            'state': authorizeUrl.queryParameters['state']!,
            'error': 'access_denied',
          }),
        ));
        return true;
      });

      await expectLater(auth.signIn(), throwsA(isA<AuthorizeDenied>()));
      expect(server.registrations, hasLength(1));
      expect(store.values[_keys.refreshTokenKey], 'rt-old');
      expect(store.values[_keys.clientIdKey], 'bm-old');
    });

    test('a registration that returns no client id is an error', () async {
      server.registerReply = (body) => http.Response(
            jsonEncode({'redirect_uris': body['redirect_uris']}),
            201,
          );

      await expectLater(
        sessionWith(browser()).signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('returned no client id'))),
      );
      expect(opened, isEmpty);
    });

    test('a registration endpoint that cannot be reached names itself',
        () async {
      server.registerReply =
          (_) => throw http.ClientException('connection refused');

      await expectLater(
        sessionWith(browser()).signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('register this app'))),
      );
      expect(opened, isEmpty);
    });

    test('a refusal with a non-JSON body names the status', () async {
      // A gateway's error page, not the authorization server's own answer.
      server.registerReply =
          (_) => http.Response('<html>bad gateway</html>', 502);

      await expectLater(
        sessionWith(browser()).signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('HTTP 502'))),
      );
      expect(opened, isEmpty);
    });

    test('a registration echoing a different redirect URI is an error, not a '
        'browser 400 later', () async {
      server.registerReply = (_) => http.Response(
            jsonEncode({
              'client_id': 'bm-test-1',
              'redirect_uris': ['http://127.0.0.1:1/elsewhere'],
            }),
            201,
          );

      await expectLater(
        sessionWith(browser()).signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('redirect URI'))),
      );
      expect(opened, isEmpty);
    });

    test('the Graph session\'s keys are untouched by an MCP sign-in', () async {
      store.values['refresh_token'] = 'graph-rt';
      store.values['granted_scopes'] = 'Mail.Read User.Read';
      store.values['account_json'] = '{"displayName":"Graph User"}';
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(email: 'ada@example.test'), refreshToken: 'rt-1'),
      ];

      await sessionWith(browser(), tools: {
        'get_profile': {'display_name': 'Ada', 'mail': 'ada@example.test'},
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
          'get_profile': {'display_name': 'Ada', 'mail': 'ada@example.test'},
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
        'get_profile': {'display_name': 'Ada', 'mail': 'ada@example.test'},
      }).signIn();

      expect(store.values.containsKey(_keys.localModeKey), isFalse);
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('a refusal on the callback is AuthorizeDenied, not a hang', () async {
      final auth = sessionWith((Uri authorizeUrl) async {
        opened.add(authorizeUrl);
        callbacks.add(_fire(
          Uri.parse(authorizeUrl.queryParameters['redirect_uri']!)
              .replace(queryParameters: {
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
        'get_profile': {'error': 'not_connected', 'connect_url': null},
      });

      final account = await auth.signIn();
      expect(account.displayName, 'ada@example.test');
      expect(account.mail, 'ada@example.test');
      // Nothing to persist — there is no profile behind it yet.
      expect(store.values.containsKey(_keys.accountJsonKey), isFalse);
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('a sign-in exchange that hangs names the step and stores nothing',
        () async {
      // Before the timeout this waited on the default http client's own, which
      // is no timeout at all: a sign-in against a black hole never came back
      // and never failed either.
      server.holdToken = heldToken;
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(
        browser(),
        requestTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        auth.signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('timed out'))),
      );
      // The code exchange is never retried — only the refresh is, and only
      // because the server graces a rotation whose reply was lost.
      expect(server.tokenPosts, hasLength(1));
      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
      expect(store.values.containsKey(_keys.clientIdKey), isFalse);
    });

    test('an unreachable profile tool does not fail the sign-in', () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-1'),
      ];
      final auth = sessionWith(browser(), tools: {
        'get_profile': const McpTransportException('connection reset'),
      });

      // No `email` claim, so the subject is the only name available.
      expect((await auth.signIn()).displayName, 'user-1');
    });
  });

  group('signIn against a server that wants no token', () {
    /// The local `make dev` server: it ANSWERS the initialize POST, which is
    /// the only thing that means "no auth wall" now. A bare GET at the same
    /// path still gets the 405 a real one gives — and that 405 is precisely
    /// what must no longer read as an open server.
    MockClient localServer() => MockClient((request) async =>
        request.method == 'POST' && request.url.path == '/mcp'
            ? http.Response(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': 0,
                  'result': {'protocolVersion': '2025-03-26'},
                }),
                200,
                headers: {'content-type': 'application/json'},
              )
            : http.Response('Method Not Allowed', 405));

    test('records local mode and needs no browser', () async {
      final store = _Tokens();
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient({
          'get_profile': {'error': 'not_connected', 'connect_url': null},
        }),
        httpClient: localServer(),
        store: store,
        openBrowser: (_) async => fail('a local server must not open a browser'),
        refreshRetryDelay: Duration.zero,
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
          'get_profile': {
            'display_name': 'Ada Lovelace',
            'mail': 'ada@example.test',
            'user_principal_name': 'ada@corp.example.test',
          },
        }),
        httpClient: localServer(),
        store: store,
        openBrowser: (_) async => fail('a local server must not open a browser'),
        refreshRetryDelay: Duration.zero,
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
      final store = _Tokens()
        ..values[_localKeys.refreshTokenKey] = 'stale-deployed-rt'
        ..values[_localKeys.clientIdKey] = 'bm-stale';
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient({
          'get_profile': {'error': 'not_connected', 'connect_url': null},
        }),
        httpClient: localServer(),
        store: store,
        openBrowser: (_) async => fail('a local server must not open a browser'),
        refreshRetryDelay: Duration.zero,
      );

      await auth.signIn();
      expect(store.values.containsKey(_localKeys.refreshTokenKey), isFalse);
      // The client id goes with the token it was issued to — one slot, one
      // lifetime, no half-state left for a later refresh to read.
      expect(store.values.containsKey(_localKeys.clientIdKey), isFalse);
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
        refreshRetryDelay: Duration.zero,
      );
      expect(await auth.validJwt(), isNull);
    });
  });

  group('the sign-in probe', () {
    /// A server whose only answer is [status] — the shape of an endpoint this
    /// app was never meant to be pointed at, and of a real one answering the
    /// wrong question.
    McpAuthSession answering(int status) => McpAuthSession(
          mcpUrl: Uri.parse(_mcp),
          mcpClient: _FakeBondMcpClient(const {}),
          httpClient: MockClient((_) async => http.Response('nope', status)),
          store: _Tokens(),
          openBrowser: (_) async =>
              fail('an unreadable answer must not open a browser'),
          refreshRetryDelay: Duration.zero,
        );

    Matcher namesStatus(int status) => throwsA(isA<AuthException>()
        .having((e) => e.message, 'message', contains('$status')));

    test('a 405 is an error, not an open server', () async {
      // The regression this whole probe exists for: FastMCP refuses a GET at
      // /mcp with 405 BEFORE its auth layer runs, so a bare GET made the
      // deployed platform look exactly like an open dev box — "signed in" with
      // no bearer, and a 401 behind every call after it.
      await expectLater(answering(405).signIn(), namesStatus(405));
    });

    test('a 403 is an error naming the status', () async {
      await expectLater(answering(403).signIn(), namesStatus(403));
    });

    test('a 400 is an error naming the status', () async {
      // What the local dev server answers a bare GET. Ambiguity is an error
      // whichever end it comes from.
      await expectLater(answering(400).signIn(), namesStatus(400));
    });

    test('a 401 with no challenge to follow is its own error', () async {
      await expectLater(
        answering(401).signIn(),
        throwsA(isA<AuthException>().having((e) => e.message, 'message',
            contains('did not say where'))),
      );
    });

    test('a 401 carrying a challenge still starts discovery', () async {
      // The deployed path is unchanged by the switch to a POST: the challenge
      // is read exactly as before.
      final server = _Server();
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_mcp),
        mcpClient: _FakeBondMcpClient(const {}),
        httpClient: server.client,
        store: _Tokens(),
        openBrowser: (_) async =>
            throw const AuthException('stop here — discovery is the point'),
        refreshRetryDelay: Duration.zero,
      );

      await expectLater(auth.signIn(), throwsA(isA<AuthException>()));
      expect(server.gets.map((u) => u.toString()),
          containsAllInOrder([_mcp, _prm, _asMetadata]));
      expect(jsonDecode(server.probes.single.body)['method'], 'initialize');
    });

    test('is an initialize POST, not a bare GET', () async {
      final seen = <http.Request>[];
      final auth = McpAuthSession(
        mcpUrl: Uri.parse(_localMcp),
        mcpClient: _FakeBondMcpClient(const {}),
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': 0}), 200);
        }),
        store: _Tokens(),
        openBrowser: (_) async => fail('an open server must not open a browser'),
        refreshRetryDelay: Duration.zero,
      );

      await auth.signIn();

      final probe = seen.single;
      expect(probe.method, 'POST');
      expect(probe.url.toString(), _localMcp);
      final body = jsonDecode(probe.body) as Map<String, dynamic>;
      expect(body['jsonrpc'], '2.0');
      expect(body['method'], 'initialize');
      expect((body['params'] as Map)['clientInfo'], isNotNull);
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
          // Nothing here waits out the real retry pause.
          refreshRetryDelay: Duration.zero,
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
      // The upgrade path: this slot holds no client id, so the token was
      // issued to the static client before ids were stored, and it keeps
      // refreshing as that client rather than being signed out.
      expect(server.tokenPosts.single['client_id'], 'bond-desktop');
      expect(server.tokenPosts.single['resource'], _mcp);
    });

    test('a refresh presents the client the session was registered as',
        () async {
      // The authorization server binds a refresh token to its client and
      // answers a mismatch with invalid_grant, so a registered session must
      // keep presenting the id it registered under.
      store.values[_keys.clientIdKey] = 'bm-old';
      server.tokenReplies = [_tokenOk(accessToken: _liveJwt())];

      expect(await session().validJwt(), isNotNull);
      expect(server.tokenPosts.single['client_id'], 'bm-old');
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
      // ...stored beside the client it was issued to. This slot had no id (the
      // upgrade path), so from here on it says which client it refreshes as.
      expect(store.values[_keys.clientIdKey], 'bond-desktop');
    });

    test('invalid_grant ends the session, and only this one', () async {
      store.values['refresh_token'] = 'graph-rt';
      store.values['granted_scopes'] = 'Mail.Read User.Read';
      store.values['account_json'] = '{"displayName":"Graph User"}';
      store.values[_keys.accountJsonKey] = '{"displayName":"Ada"}';
      store.values[_keys.localModeKey] = '1';
      store.values[_keys.clientIdKey] = 'bm-old';
      server.tokenReplies = [
        http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
      ];

      await expectLater(session().validJwt(), throwsA(isA<NotSignedIn>()));

      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
      expect(store.values.containsKey(_keys.clientIdKey), isFalse);
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

  group('refresh robustness', () {
    late _Server server;
    late _Tokens store;
    late Completer<void> heldToken;

    McpAuthSession session({Duration? requestTimeout}) => McpAuthSession(
          mcpUrl: Uri.parse(_mcp),
          mcpClient: _FakeBondMcpClient(const {}),
          httpClient: server.client,
          store: store,
          requestTimeout: requestTimeout,
          // Nothing here waits out the real retry pause.
          refreshRetryDelay: Duration.zero,
        );

    setUp(() {
      server = _Server();
      // The client id is seeded beside the token so the tests below can say
      // that a session ending takes BOTH halves of the pair with it.
      store = _Tokens()
        ..values[_keys.refreshTokenKey] = 'rt-1'
        ..values[_keys.clientIdKey] = 'bm-1';
      heldToken = Completer<void>();
    });

    tearDown(() {
      if (!heldToken.isCompleted) heldToken.complete();
    });

    test('a refresh that hangs times out and keeps the token', () async {
      // The hold is never released inside the test, so BOTH attempts wait out
      // the timeout. Before it there was no timeout at all: a refresh into a
      // black hole pinned the single-flight guard until the app was
      // relaunched, and every call behind it waited forever.
      server.holdToken = heldToken;
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-2'),
      ];
      final auth = session(requestTimeout: const Duration(milliseconds: 50));

      await expectLater(
        auth.validJwt(),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
      expect(server.tokenPosts, hasLength(2));
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('a refresh interrupted on the wire is retried once and succeeds',
        () async {
      // The case this exists for: the first attempt may well have REACHED the
      // server, which rotated the token and lost the reply coming back. The
      // authorization server honours a second presentation while the successor
      // is unused, so the retry costs nothing and saves a sign-in.
      server.tokenReplies = [
        http.ClientException('connection reset'),
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-2'),
      ];

      expect(await session().validJwt(), isNotNull);
      expect(server.tokenPosts, hasLength(2));
      expect(server.tokenPosts.map((post) => post['grant_type']),
          everyElement('refresh_token'));
      // The SAME token both times: the grace is keyed on the presented one.
      expect(server.tokenPosts.map((post) => post['refresh_token']),
          everyElement('rt-1'));
      expect(store.values[_keys.refreshTokenKey], 'rt-2');
    });

    test('a refresh that fails twice on the wire is an error and keeps the '
        'token', () async {
      server.tokenReplies = [
        http.ClientException('connection reset'),
        http.ClientException('connection reset again'),
      ];

      await expectLater(
        session().validJwt(),
        // An AuthException, deliberately not a NotSignedIn: a network that is
        // down has said nothing about the session.
        throwsA(allOf(isA<AuthException>(), isNot(isA<NotSignedIn>()))),
      );
      expect(server.tokenPosts, hasLength(2));
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    test('an HTTP error is the server answering, and is not retried', () async {
      // A status is the server's judgement — it arrived, so there is nothing
      // to make invisible, and a retry would only double the load on a server
      // that is already struggling.
      server.tokenReplies = [http.Response('upstream exploded', 500)];

      await expectLater(session().validJwt(), throwsA(isA<AuthException>()));
      expect(server.tokenPosts, hasLength(1));
      expect(store.values[_keys.refreshTokenKey], 'rt-1');
    });

    /// Each `error_reason` the authorization server sends, and the sentence
    /// the user is shown for it. These strings ARE the UI: the inbox renders
    /// them as its load error when the session ends.
    const endings = {
      'expired':
          'Your session expired after a month without use — sign in again.',
      'revoked': 'Your session was ended on the server — sign in again.',
      'client_mismatch': "Your saved session no longer matches this app's "
          'registration — sign in again.',
      'unknown':
          'The server no longer recognizes your session — sign in again.',
    };

    for (final ending in endings.entries) {
      test('a session ended as ${ending.key} says so', () async {
        // One "Session expired" for four different causes made a month of
        // inactivity indistinguishable from a revoked grant in the field.
        server.tokenReplies = [
          http.Response(
            jsonEncode({
              'error': 'invalid_grant',
              'error_reason': ending.key,
              'error_description': 'operator-facing detail, not for the user',
            }),
            400,
          ),
        ];

        await expectLater(
          session().validJwt(),
          throwsA(isA<NotSignedIn>()
              .having((e) => e.message, 'message', ending.value)),
        );
        expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
        // The client id goes with the token it was issued to, whatever ended
        // the session.
        expect(store.values.containsKey(_keys.clientIdKey), isFalse);
      });
    }

    test('a session ended with no reason given keeps the old wording',
        () async {
      // `error_reason` is a non-standard extension: an older authorization
      // server sends none, and must still end the session cleanly.
      server.tokenReplies = [
        http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
      ];

      await expectLater(
        session().validJwt(),
        throwsA(isA<NotSignedIn>().having(
            (e) => e.message, 'message', 'Session expired — sign in again.')),
      );
      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
    });
  });

  group('the slot lock', () {
    late _Server server;
    late _Tokens store;
    late List<Uri> opened;
    late List<Future<void>> callbacks;
    late Completer<void> heldToken;

    /// The browser stand-in, as in the sign-in group: it records the authorize
    /// URL and drives the loopback listener the way a real redirect would.
    Future<bool> Function(Uri) browser() => (Uri authorizeUrl) async {
          opened.add(authorizeUrl);
          callbacks.add(_fire(
            Uri.parse(authorizeUrl.queryParameters['redirect_uri']!)
                .replace(queryParameters: {
              'state': authorizeUrl.queryParameters['state']!,
              'code': 'the-auth-code',
            }),
          ));
          return true;
        };

    McpAuthSession sessionWith(Future<bool> Function(Uri) openBrowser) =>
        McpAuthSession(
          mcpUrl: Uri.parse(_mcp),
          mcpClient: _FakeBondMcpClient(const {}),
          httpClient: server.client,
          store: store,
          openBrowser: openBrowser,
          refreshRetryDelay: Duration.zero,
        );

    setUp(() {
      server = _Server();
      // A session already signed in to the deployed server: the only state in
      // which a refresh can race anything.
      store = _Tokens()
        ..values[_keys.refreshTokenKey] = 'rt-old'
        ..values[_keys.clientIdKey] = 'bm-old';
      opened = [];
      callbacks = [];
      // Every test here freezes the refresh mid-flight; tearDown releases it
      // so a held request can never outlive its test.
      heldToken = Completer<void>();
      server.holdToken = heldToken;
    });

    tearDown(() async {
      if (!heldToken.isCompleted) heldToken.complete();
      await Future.wait(callbacks);
    });

    test('a refresh already in flight lands before a sign-in writes its '
        'session', () async {
      server.registerReply = _registerOk('bm-new');
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-old-2'),
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-new'),
      ];
      final auth = sessionWith(browser());

      final refresh = auth.validJwt();
      await _until(
          'the refresh has been sent', () => server.tokenPosts.length == 1);
      final signIn = auth.signIn();
      await _until('the browser has been opened', () => opened.length == 1);
      // The loopback reply having been read means the sign-in HAS its code and
      // is on its way to the exchange.
      await Future.wait(callbacks);
      await _settle();

      // It registered and ran its whole browser round while the refresh was
      // frozen — that part is deliberately outside the lock — but its exchange
      // is waiting.
      expect(server.registrations, hasLength(1));
      expect(server.tokenPosts, hasLength(1));

      heldToken.complete();
      await refresh;
      await signIn;

      expect(server.tokenPosts[0]['grant_type'], 'refresh_token');
      expect(server.tokenPosts[1]['grant_type'], 'authorization_code');
      // The session the user just signed in to — not the rotated pair of the
      // one they replaced, landing a moment later on top of it.
      expect(store.values[_keys.refreshTokenKey], 'rt-new');
      expect(store.values[_keys.clientIdKey], 'bm-new');
    });

    test('signing out during a refresh leaves the slot empty', () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-old-2'),
      ];
      final auth = sessionWith((_) async => fail('no browser in a sign-out'));

      final refresh = auth.validJwt();
      await _until(
          'the refresh has been sent', () => server.tokenPosts.length == 1);
      final signedOut = auth.signOut();
      await _settle();

      // Sign-out waits: clearing now would be undone by the refresh landing
      // after it and writing the rotated token back — a signed-out app holding
      // a live session, which is the ghost this lock kills.
      expect(store.values[_keys.refreshTokenKey], 'rt-old');

      heldToken.complete();
      await refresh;
      await signedOut;

      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
      expect(store.values.containsKey(_keys.clientIdKey), isFalse);
      expect(await auth.isSignedIn, isFalse);
    });

    test('a local sign-in during a refresh wins', () async {
      server.tokenReplies = [
        _tokenOk(accessToken: _liveJwt(), refreshToken: 'rt-old-2'),
      ];
      final auth = sessionWith(
          (_) async => fail('an open server must not open a browser'));

      // The refresh starts against the challenged server — its discovery needs
      // that 401 — and only THEN does the same URL come back with auth off,
      // which is a local box rebooted without it.
      final refresh = auth.validJwt();
      await _until(
          'the refresh has been sent', () => server.tokenPosts.length == 1);
      server.openServer = true;
      final signIn = auth.signIn();
      await _settle();

      heldToken.complete();
      await refresh;
      await signIn;

      // One slot, one session: the local flag stands and the pair the refresh
      // rotated is gone, rather than a refresh token left behind to win over
      // the flag in validJwt.
      expect(store.values[_keys.localModeKey], '1');
      expect(store.values.containsKey(_keys.refreshTokenKey), isFalse);
      expect(store.values.containsKey(_keys.clientIdKey), isFalse);
      expect(await auth.validJwt(), isNull);
    });

    test('a refresh that lands after a local sign-in sends no bearer rather '
        'than ending the session', () async {
      // The other order, and the one that used to be wrong. This refresh is
      // frozen in DISCOVERY, which runs outside the lock, so the local sign-in
      // takes the slot first and deletes the pair on purpose. validJwt had
      // read a refresh token before any of that and must not hold the user to
      // it: what it is looking at now is a live session that sends no bearer,
      // and a NotSignedIn here would put "You are not signed in." on the inbox
      // a moment after a sign-in that worked.
      final heldMetadata = Completer<void>();
      server.holdMetadata = heldMetadata;
      final auth = sessionWith(
          (_) async => fail('an open server must not open a browser'));

      final refresh = auth.validJwt();
      await _until('discovery has reached the metadata document',
          () => server.gets.map((url) => url.toString()).contains(_asMetadata));
      server.openServer = true;
      await auth.signIn();

      heldMetadata.complete();
      expect(await refresh, isNull);
      // It never presented the token the local sign-in had already retired.
      expect(server.tokenPosts, isEmpty);
      expect(store.values[_keys.localModeKey], '1');
    });
  });
}

/// Drives the loopback listener the way a browser redirect would. Failures are
/// swallowed: the server is force-closed the instant sign-in resolves, which
/// can cut the socket before the reply is fully read.
Future<void> _fire(Uri url) =>
    http.get(url).then((_) {}, onError: (Object _) {});

/// Yields the event loop until [condition] holds.
///
/// These are real futures over a real socket, not a fake clock, so the only
/// way to let something already in flight get further is to hand the loop back
/// and look again. Bounded, so a condition that never holds fails by name
/// instead of hanging the run.
Future<void> _until(String what, bool Function() condition) async {
  for (var turn = 0; turn < 200; turn++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('gave up waiting until $what');
}

/// Yields the event loop a few times, for the assertions that say something
/// has NOT happened: without this they would pass on a lock that does not
/// exist yet simply because nothing had run.
Future<void> _settle([int turns = 20]) async {
  for (var turn = 0; turn < turns; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}
